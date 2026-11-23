# Case Study 11: Distributed Job Scheduler (cron at scale / Airflow / Temporal-lite)

> Tests: leader election, leases, at-least-once vs exactly-once execution, time-based triggering at scale, and worker failure handling.

## 1. Requirements

**Functional**

- Submit jobs: one-off (run at time T) and recurring (cron expressions)
- Execute jobs on a worker fleet; retries with backoff on failure
- Job status, history, cancellation
- Optional: dependencies (DAGs), priorities, rate limits per tenant

**Non-functional**

- Scale: 100M scheduled jobs; peak 100K jobs/s triggering (everyone schedules "at midnight")
- Trigger accuracy: within ~1s of the scheduled time
- **Each job runs at least once; ideally exactly once** (effectively, via idempotency)
- No single point of failure

## 2. Data model

```
jobs(job_id, tenant_id, schedule (cron | timestamp), payload, handler, retry_policy, status, next_run_at, version)
job_runs(run_id, job_id, scheduled_for, attempt, status: PENDING|CLAIMED|RUNNING|SUCCEEDED|FAILED,
         worker_id, lease_expires_at, started_at, finished_at, result)
  UNIQUE(job_id, scheduled_for)   ← prevents creating the same run twice
```

## 3. High-level design

```
API → Job Store (sharded DB)
          ↑               \
   Scheduler (triggers)    → Ready Queue (Kafka/SQS/Redis, partitioned) → Workers (pull, lease, execute, heartbeat)
   [partitioned by job_id shard; leader per partition]          ↓
                                                    Run status updates → Job Store; retries re-enqueued with delay
```

Two separate concerns:

1. **Triggering:** finding jobs whose time has come and creating runs.
2. **Execution:** reliably running each run on a worker.

## 4. Deep dive: triggering without duplicates or misses

**Naive:** one scheduler process scans `WHERE next_run_at <= now()`. That's a single point of failure. Running three for HA means three triggers per job.

**Solution: partitioned scheduler with leadership per partition**

- Split jobs into N partitions (e.g., by `hash(job_id) % 1024`).
- Scheduler instances acquire **leases on partitions** (etcd/ZooKeeper, or a lease table with fencing tokens). Each partition has exactly one active owner.
- The owner polls its partition: `SELECT ... WHERE partition=? AND next_run_at <= now() + lookahead ORDER BY next_run_at LIMIT 1000`.
- For each due job, **atomically**:
    ```sql
    BEGIN;
    INSERT INTO job_runs(job_id, scheduled_for, status='PENDING') ...;      -- UNIQUE(job_id, scheduled_for) dedupes
    UPDATE jobs SET next_run_at = :next_cron_time, version=version+1
       WHERE job_id=? AND version=:v;                                         -- optimistic guard
    COMMIT;
    ```
    Then enqueue the run (via an outbox to the ready queue).
- **Even if two schedulers briefly overlap** (lease handover, GC pause), the unique constraint on `(job_id, scheduled_for)` prevents a duplicate run. The fencing token on the lease adds a second layer.

**Precise timing at scale: time-bucketed or in-memory timer wheels**

- Pre-load jobs due in the next minute into an in-memory **timing wheel / min-heap** per partition and fire them precisely.
- Alternative: Redis sorted set `ZADD due:{partition} <timestamp> run_id`; poll `ZRANGEBYSCORE due 0 now LIMIT 1000` and atomically claim with a Lua script (`ZREM` succeeds for only one poller).

**The midnight problem (thundering herd):** many jobs scheduled at 00:00:00.

- Spread load: jitter where acceptable ("daily" means sometime in a window), or pre-enqueue with a "not before" time.
- Scale workers ahead of known peaks; priority by tier.

## 5. Deep dive: execution and worker failures

**Claim with lease (visibility timeout pattern):**
```sql
UPDATE job_runs SET status='RUNNING', worker_id=:w, lease_expires_at=now()+interval '60s', attempt=attempt+1
WHERE run_id=:r AND (status='PENDING' OR (status='RUNNING' AND lease_expires_at < now()))
```
or use the queue's semantics (SQS visibility timeout; Kafka consumer + external lease).

- Worker **heartbeats** to extend the lease while running.
- Worker dies → lease expires → another worker claims → **the job runs again**. So:

**Exactly-once is not achievable for arbitrary side effects.** Provide:

- **At-least-once execution** + a **fencing token** (attempt number / lease version) passed to the job, so downstream systems can reject stale attempts.
- Ask job authors to make handlers **idempotent** (e.g., use `run_id` as an idempotency key for external calls).
- Mark completion with a conditional update: `UPDATE job_runs SET status='SUCCEEDED' WHERE run_id=? AND worker_id=? AND attempt=?`. A zombie worker's late completion is rejected.

**Retries:** exponential backoff with jitter; max attempts → FAILED → DLQ/alert. Distinguish retryable from non-retryable errors.

## 6. Deep dive: scaling the job store

- 100M jobs, sharded by `job_id` (or tenant). The index on `(partition, next_run_at)` makes due-job scans cheap.
- `job_runs` grows fast: TTL/archive old runs to cold storage.
- Hot tenants: per-tenant concurrency limits and quotas (fairness), separate queues per priority.

## 7. Workflow / DAG extension

- Job dependencies: a run becomes ready when all its parents succeed. Store edges; on completion, decrement a counter on children (atomic) and enqueue those reaching zero.
- For long-running, multi-step workflows with state, use a **durable execution engine** (Temporal/Cadence): event-sourced workflow history, deterministic replay, timers, and activity retries. This is how Uber, Netflix, and Stripe run business workflows.

## 8. Failure modes

| Failure | Handling |
|---|---|
| Scheduler instance dies | Partition leases expire → other instances take over (≤ lease TTL delay); catch up on missed due jobs (`next_run_at <= now()`) |
| Scheduler paused past its lease | Fencing token + unique run constraint prevent duplicate runs |
| Worker dies mid-job | Lease expiry → retry (job must be idempotent) |
| Queue backlog | Autoscale workers on queue depth; priority lanes |
| Clock skew between schedulers | Use DB time (`now()` from the DB) or a single time source per partition owner |
| Downstream outage causing mass failures | Circuit break per handler; pause the queue; backoff |

## 9. Follow-ups

- **Missed runs after a long outage:** policy per job (run once to catch up, run all missed, skip).
- **Cancellation:** a status flag checked before claim and periodically by running jobs (cooperative).
- **Exactly-once for DB-only jobs:** run the job's DB writes and the `SUCCEEDED` update in the same transaction.
- **Why not Kubernetes CronJobs?** That's fine at small scale; this design is for multi-tenant, millions of jobs.
