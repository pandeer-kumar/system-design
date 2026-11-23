# Task Queues: RabbitMQ, SQS, Celery, Sidekiq, and DB-Backed Queues

> "Send an email after signup," "resize this image," "charge the card at shipment": almost every system has background jobs. This chapter covers how task queues work inside, how they differ from Kafka, and how to make them reliable. To design one from scratch, see [case study 25](../06-case-studies/25-distributed-task-queue.md).

## 1. What a task queue does

```
Producer ──enqueue(task)──> Broker (queue) ──deliver──> Worker ──ack──> Broker deletes task
                                  │                        │
                                  └── redeliver if no ack ─┘ (crash / timeout)
```

Core features, and why each one matters:

| Feature | Why |
|---|---|
| **Per-message acknowledgement** | A task is removed only after a worker confirms it's done |
| **Redelivery on failure** (visibility timeout / unacked on disconnect) | A crashed worker's tasks aren't lost |
| **Retries with backoff** | Transient failures (downstream 503) heal themselves |
| **Dead-letter queue (DLQ)** | Poison tasks stop blocking and get human attention |
| **Delayed / scheduled tasks** | "Send reminder in 24h," exponential backoff |
| **Priorities** | Password-reset emails before marketing emails |
| **Concurrency control / prefetch** | Workers aren't flooded; backpressure |
| **Competing consumers** | Add workers to scale horizontally |

**Delivery guarantee:** at-least-once in practice. **Workers must be idempotent.**

## 2. Task queue vs log (Kafka): when to use which

| | Task queue (SQS, RabbitMQ, Celery) | Log (Kafka, Kinesis) |
|---|---|---|
| Unit of work | Independent tasks | Ordered stream of events |
| Ack | Per message | Per partition offset |
| One slow/failed task | Others continue (other workers pick other tasks) | **Blocks its partition** |
| Retry with delay | Native | Retry topics (workaround) |
| Priority | RabbitMQ native; SQS via separate queues | Separate topics |
| Replay history | No | Yes |
| Multiple independent consumers of the same data | Fan-out via exchanges / SNS | Native (consumer groups) |
| Scaling consumers | Any number | ≤ partition count |
| Ordering | Mostly none (FIFO options exist) | Per partition |

**Rule of thumb:** *commands/jobs* → task queue. *Events/facts that many systems consume, or that need replay or ordering* → log. Many systems use both: an event lands on Kafka, and a consumer turns it into tasks on SQS.

## 3. RabbitMQ internals

### AMQP model
```
Producer → Exchange ──(binding rules)──> Queue(s) → Consumer
```

| Exchange type | Routing |
|---|---|
| Direct | Routing key matches the binding key exactly |
| Topic | Pattern match (`order.*.created`, `#.error`) |
| Fanout | Every bound queue (pub/sub) |
| Headers | Match on message headers |

### Reliability mechanisms

- **Publisher confirms:** the broker acknowledges to the publisher once the message is safely stored (and replicated, for quorum queues). Without confirms, a publish can be silently lost.
- **Consumer acks:** manual `basic.ack` after processing. `basic.nack`/`reject` with `requeue=false` sends the message to the **dead-letter exchange (DLX)**.
- **Unacked messages** are redelivered when the consumer's channel or connection closes (there's no timeout by default; `consumer_timeout`, 30 min default, kills consumers that hold messages too long).
- **Prefetch (`basic.qos`)**: max unacked messages per consumer. Low prefetch = fair dispatch and no hoarding; high prefetch = throughput. Start around 10–50 for slow tasks, higher for fast ones.

### Queue types

| | Classic | **Quorum** (recommended for durability) | Streams |
|---|---|---|---|
| Replication | None (mirroring removed in 4.0) | **Raft** across 3/5 nodes | Raft-replicated log |
| Durability | Single node | Survives minority failures | Survives minority failures |
| Features | Priorities, lazy mode | Poison-message handling (delivery limit), at-least-once | Replay, multiple consumers like Kafka |
| Use | Transient, low-value | **Default for important work** | Log-style use in RabbitMQ |

### Delays and TTL

- Per-queue or per-message TTL, plus DLX gives "delayed retry": publish to a wait queue with a TTL, whose DLX routes back to the work queue.
- The delayed-message plugin supports arbitrary per-message delays (has scale limits).

### Flow control
When memory or disk passes its watermark, RabbitMQ **blocks publishers** (TCP backpressure). That protects the broker, but your producers stall, so monitor it.

### Scale profile
Tens of thousands of messages/s per node is comfortable. It suits complex routing, priorities, and RPC-style patterns. It's not built for Kafka-level throughput or long retention.

## 4. Amazon SQS internals (as far as is public)

- **Fully managed, distributed, and redundant.** Messages are stored redundantly across multiple AZs. Nearly unlimited throughput for Standard queues.
- **Standard queue:** at-least-once, best-effort ordering, rare duplicates (possible even without failures, because it's highly distributed).
- **FIFO queue:** ordering per **message group ID**, exactly-once *processing* within a **5-minute dedup window** (by `MessageDeduplicationId` or content hash). Throughput ~300 messages/s per API action without batching, much higher in high-throughput mode. Messages in a group are delivered one batch at a time: while a group has in-flight messages, others in that group wait, so **parallelism = number of active groups**.
- **Visibility timeout** (default 30 s, max 12 h): `ReceiveMessage` hides the message; if the worker doesn't `DeleteMessage` in time, it reappears. A long task should **extend** the timeout via `ChangeMessageVisibility` (heartbeat).
- **Long polling** (`WaitTimeSeconds` up to 20) reduces empty responses and cost.
- **DLQ** via redrive policy after `maxReceiveCount`; redrive back from the DLQ after a fix.
- **Delay queues / per-message delay:** up to 15 minutes. For longer delays use EventBridge Scheduler, Step Functions, or your own scheduler.
- **Message size:** up to 1 MiB (256 KB before 2025). For larger payloads, store them in S3 and send a pointer (the extended client library does this).
- **Retention:** 1 minute to 14 days (4 days default).
- **Cost model:** per request (batch up to 10 messages per call).

**SQS + SNS fan-out:** publish once to an SNS topic, deliver to multiple SQS queues (one per consumer service). That's the AWS-native pub/sub for tasks.

## 5. Celery (Python), Sidekiq (Ruby), BullMQ (Node)

These are **frameworks** on top of a broker.

### Celery

- Brokers: RabbitMQ (recommended) or Redis (or SQS). Optional **result backend** (Redis, DB) for task return values.
- **`acks_late=True`**: ack after the task runs (at-least-once) rather than before (at-most-once, the default). Use it with idempotent tasks.
- **`worker_prefetch_multiplier`**: how many tasks each worker process reserves. Set it to 1 for long tasks, so one worker doesn't hoard tasks while others sit idle.
- **Redis broker gotcha:** Redis has no native ack, so Celery emulates a **visibility timeout** (default 1 hour). A task longer than that gets **redelivered and runs twice**. ETA/countdown tasks longer than the visibility timeout are also re-executed.
- `task_reject_on_worker_lost=True` re-queues tasks if the worker process is killed (e.g., OOM).
- Beat scheduler for periodic tasks. It's a single instance; running two means duplicate schedules, so use a lock-based or DB-backed beat.

### Sidekiq

- Redis lists; extremely efficient (multithreaded Ruby workers).
- The open-source version uses `BRPOP`, so a worker crash mid-job **loses the job**. Sidekiq Pro's "super fetch" uses `LMOVE` to a per-process working list for reliability.
- Retries with exponential backoff (25 retries over ~21 days by default), a dead set, and scheduled jobs in a sorted set.

### BullMQ

- Redis-based (Streams/lists + Lua scripts). Supports delays, priorities, rate limiting, repeatable jobs, flows (parent/child jobs), and stalled-job detection via locks with renewal.

## 6. Database-backed queues (often the right answer)

```sql
CREATE TABLE jobs (
  id bigserial PRIMARY KEY,
  queue text, payload jsonb,
  run_at timestamptz DEFAULT now(),
  attempts int DEFAULT 0,
  locked_until timestamptz,
  status text DEFAULT 'pending'
);
CREATE INDEX ON jobs (queue, run_at) WHERE status = 'pending';

-- Claim up to 10 jobs; concurrent workers skip each other's rows
WITH next AS (
  SELECT id FROM jobs
  WHERE queue = 'email' AND status = 'pending' AND run_at <= now()
  ORDER BY run_at
  LIMIT 10
  FOR UPDATE SKIP LOCKED
)
UPDATE jobs SET status = 'running', locked_until = now() + interval '5 min', attempts = attempts + 1
FROM next WHERE jobs.id = next.id
RETURNING jobs.*;
```

- **Big advantage: transactional enqueue.** Insert the job **in the same transaction** as your business write. No dual-write problem and no outbox needed.
- A reaper resets `running` jobs whose `locked_until` has passed (worker died).
- Libraries: **pg-boss** (Node), **River** (Go), **Oban** (Elixir), **GoodJob**/**Solid Queue** (Rails), Graphile Worker; `LISTEN/NOTIFY` for low-latency wakeups.
- **Limits:** a few thousand jobs/s per database is comfortable. Heavy churn creates dead tuples, so tune autovacuum and delete or partition completed jobs. Beyond that, move to a dedicated broker.

## 7. Making task processing reliable: the checklist

1. **Idempotent tasks.** Use a task ID / idempotency key; check-and-record in the same transaction as the side effect; pass the key downstream (e.g., to the payment provider).
2. **Ack after success** (acks_late / delete after processing).
3. **Visibility timeout > p99 task duration**, plus a heartbeat to extend it for long tasks. Otherwise the task runs twice concurrently.
4. **Retries with exponential backoff and jitter;** classify errors as retryable vs permanent (a validation error shouldn't retry 25 times).
5. **DLQ** after N attempts, with alerting and a redrive tool.
6. **Timeouts inside the task** for every external call (a stuck task holds a worker forever).
7. **Payloads small:** pass IDs, not whole objects (the object may change; big messages are slow). Re-read current state in the worker.
8. **Bounded concurrency** per downstream (don't let 500 workers hammer a DB that takes 50 connections).
9. **Graceful shutdown:** stop taking new tasks, finish or requeue in-flight ones on SIGTERM (deploys).
10. **Observability:** queue depth, **age of the oldest message** (the best SLO signal), processing rate, failure rate, DLQ size, retries.

## 8. Design problems specific to task queues

### Fairness and noisy tenants
One tenant enqueues 10M tasks; everyone else waits behind them.

- **Queue per tenant** (or per tenant tier) with round-robin or weighted fair dequeue across queues.
- **Per-tenant concurrency limits** (a semaphore per tenant in Redis).
- **Shuffle sharding** of tenants onto worker pools.

### Priorities without starvation

- Separate queues per priority, with workers polling high-priority first.
- Pure strict priority starves low priority under sustained load. Use **weighted** polling (e.g., 6:3:1) or dedicated workers per tier.

### Long-running tasks

- Heartbeats extend leases; checkpoint progress so a retry resumes rather than restarting.
- Split them into smaller tasks (chunked fan-out + a completion counter), or use a workflow engine (Temporal) that persists progress.

### Fan-out / fan-in (map-reduce style)

- The parent enqueues N child tasks plus a counter `remaining = N` (atomic `DECR` in Redis or a DB counter). The child that brings it to 0 enqueues the "finalize" task. Celery chords and BullMQ flows implement this.
- Make the finalize step idempotent (it can be triggered twice on retries).

### Scheduled and delayed tasks at scale

- Small delays: the broker's native delay (SQS ≤ 15 min).
- Large or long delays: a store indexed by run time (a DB index on `run_at`, a Redis sorted set, or a hierarchical **timing wheel** in memory), with a poller moving due tasks into the ready queue. See [job scheduler](../06-case-studies/11-job-scheduler.md).

### Ordering
Most task queues don't order. If needed, use SQS FIFO message groups, a single consumer per key, or version checks in the task ("apply only if newer than the stored version").

### Autoscaling workers

- Scale on **backlog per worker** or **oldest message age**, not CPU (an I/O-bound worker can sit at low CPU with a huge backlog). KEDA on Kubernetes; target tracking on SQS `ApproximateNumberOfMessagesVisible` / `ApproximateAgeOfOldestMessage`.
- Scale-in carefully: graceful shutdown so in-flight tasks aren't abandoned.

## 9. Choosing

| Situation | Choice |
|---|---|
| AWS, simple background jobs, minimal ops | **SQS** (+ DLQ, + SNS for fan-out) |
| Complex routing, priorities, RPC, on-prem | **RabbitMQ** (quorum queues) |
| Python app | **Celery** on RabbitMQ (or SQS) |
| Ruby / Node app | **Sidekiq** / **BullMQ** on Redis |
| Already on Postgres, < few thousand jobs/s, want transactional enqueue | **Postgres `SKIP LOCKED`** (pg-boss, River, Solid Queue) |
| Multi-step, long-running business processes with state, timers, compensation | **Temporal** / Step Functions |
| High-throughput event stream that also drives work | **Kafka** → consumers (possibly feeding a task queue) |
| GCP | Cloud Tasks (rate-limited HTTP task dispatch) or Pub/Sub |

## 10. Interview questions

1. **A worker crashes mid-task. What happens?** No ack, so after the visibility timeout (SQS) or connection close (RabbitMQ) the task is redelivered. The task must be idempotent.
2. **A task takes 40 minutes; the visibility timeout is 30. What goes wrong?** The task reappears and a second worker runs it concurrently. Extend visibility with a heartbeat, or set the timeout above p99 duration.
3. **How do you avoid duplicate emails?** Dedup key (user, notification ID) recorded atomically before sending, and pass provider idempotency keys where supported. Accept that exactly-once to SMTP isn't possible.
4. **How do you enqueue a task atomically with a DB write?** Transactional outbox, or a DB-backed queue in the same transaction.
5. **How do you prevent one customer from starving others?** Per-tenant queues with fair scheduling, per-tenant concurrency limits, and shuffle sharding.
6. **Why not use Kafka for this job queue?** Per-message retries and delays aren't native; a poison message blocks its partition; parallelism is capped by the partition count. A queue fits better.
7. **What do you alert on?** Age of the oldest message relative to the SLO, DLQ growth, failure rate, and worker saturation.
8. **How does SQS FIFO give exactly-once?** A 5-minute dedup window on the send side, plus one-at-a-time delivery per message group. Consumer processing still needs idempotency if it can exceed the visibility timeout.
