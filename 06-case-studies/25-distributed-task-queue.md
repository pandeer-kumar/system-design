# Case Study 25: Distributed Task Queue (design SQS / Celery backend)

> Tests: at-least-once delivery, visibility timeouts and leases, delayed messages, FIFO with message groups, fairness across tenants, durable replicated storage, and hot-queue scaling. A very common FAANG question, framed as "design a job queue," "design SQS," or "design a background processing system." Background reading: [task queues deep dive](../09-technology-deep-dives/03-task-queues.md).

## 1. Requirements

**Functional**

- `CreateQueue`, `SendMessage(queue, body, delay?, group_id?, dedup_id?)`
- `ReceiveMessage(queue, max=10, wait_seconds, visibility_timeout)` → messages + receipt handles
- `DeleteMessage(receipt_handle)` (ack), `ChangeVisibility(receipt_handle, seconds)` (heartbeat)
- Retries with a max receive count → **dead-letter queue**
- Delayed delivery (seconds to hours), optional FIFO per message group

**Non-functional**

- Multi-tenant; millions of queues; a single hot queue may need 100K+ msgs/s
- **Durability:** an acknowledged `SendMessage` is never lost (survives an AZ failure)
- **At-least-once** delivery (exactly-once only within constraints for FIFO)
- Send/receive latency p99 < 20–50 ms
- Highly available (99.99%), horizontally scalable

## 2. Estimation

- 1M msgs/s aggregate send, the same for receive and delete → ~3M API calls/s (batching up to 10 per call cuts requests ~5×).
- Average message 4 KB → 4 GB/s ingest; retention 4 days, but most messages live seconds → steady-state stored data is dominated by backlog, not throughput. Size storage for **worst-case backlog** (consumers down for hours): 1M/s × 3,600 s × 4 KB ≈ 14 TB per hour of outage, × 3 replicas.

## 3. API semantics to pin down (interviewers probe these)

- **Receipt handle:** each receive returns a new handle tied to *that delivery*. `Delete` with an old handle (after the message was redelivered to someone else) must not delete the newer delivery, or must, depending on semantics; SQS lets it succeed. State your choice. Safer: the handle encodes `(message_id, delivery_attempt)`, and delete/extend validate the attempt (a **fencing token**).
- **Visibility timeout:** while invisible, no other consumer receives it. On expiry, it becomes visible again and `receive_count` increments.
- **`receive_count > maxReceiveCount`** → move to the DLQ instead of delivering.
- **Long polling:** hold the receive request up to `wait_seconds` until messages arrive (cuts empty receives).

## 4. High-level architecture

```
Clients ─► Front-end fleet (stateless: auth, validation, throttling, routing)
                 │  queue → partitions map (metadata service, cached)
                 ▼
          Queue partitions (storage nodes), each partition = replicated log + indexes
                 │   replicated 3 ways across AZs (Raft / primary-backup with quorum ack)
                 ▼
          Per-partition in-memory state: ready index, in-flight (visibility) timer wheel, delay index
Metadata service (strongly consistent: etcd/ZooKeeper-like or a DynamoDB table):
          queue config, partition assignments, leader per partition
Background: DLQ mover, retention sweeper, partition rebalancer/splitter, metrics
```

**Why partitions:** one queue's throughput must exceed one machine. A queue is split into N **partitions** (shards); each partition is owned by one leader node (single writer, no locking) with replicas.

## 5. Deep dive: storage and durability of a partition

**Write path (`SendMessage`):**

1. The front end picks a partition: random or least-loaded for Standard queues (any partition can hold any message); `hash(group_id)` for FIFO.
2. Partition leader appends the message to its **replicated log** (WAL) and waits for a **quorum** (2 of 3 replicas in different AZs) to persist it.
3. Only then does it reply 200 → durable ack.
4. The leader updates the in-memory **ready index** (or the **delay index** if `delay > 0`).

**State per message:** `message_id, body (or pointer to blob store if large), enqueue_ts, visible_at, receive_count, current_attempt, group_id, dedup_id`.

**Log + indexes design:** the log is append-only (fast writes). State changes (delivered, visibility extended, deleted) are **also appended as log records**. That makes the replicated log the single source of truth, and in-memory indexes are rebuilt by replay after a leader failover. Periodic snapshots + log compaction drop deleted messages.

Alternative: store messages in a replicated KV store (e.g., a Raft-backed RocksDB per partition) keyed by `(visible_at, message_id)`, so "next visible message" is a range scan. Equivalent; mention either.

## 6. Deep dive: receive, visibility timeout, ack (the concurrency core)

**Receive:**

1. The front end picks partitions (round-robin across the queue's partitions, skipping empty ones).
2. The partition leader pops up to N messages from the ready index whose `visible_at ≤ now`, sets `visible_at = now + visibility_timeout`, increments `receive_count` and `attempt`, and appends this state change to the log (replicated) **before** returning. Otherwise, a leader crash would forget that the message was handed out, which is safe (just a duplicate) but should be bounded.
3. Puts them into the **in-flight timer wheel** keyed by `visible_at`.
4. Returns messages with receipt handles `(partition, message_id, attempt)`.

Because the partition leader is a **single thread/actor for its state**, two consumers can never receive the same message concurrently. No distributed locks are needed.

**Delete (ack):** validate the receipt handle's attempt matches the current attempt; mark deleted (log append); remove from indexes. If it doesn't match (the message timed out and was redelivered), reject or ignore. That stops a slow, "zombie" consumer from acknowledging a delivery that someone else now owns.

**Visibility expiry:** the timer wheel fires → the message moves back to the ready index (or to the DLQ if `receive_count ≥ max`). The hierarchical timing wheel gives O(1) insert/expire for millions of in-flight messages.

**ChangeVisibility (heartbeat):** move the message in the timer wheel; validate the handle.

**Why at-least-once and not exactly-once:** a consumer may finish processing but crash before `Delete`; the message reappears. Nothing in the queue can know the side effect happened. **Consumers must be idempotent** (dedup by message_id).

## 7. Deep dive: delayed messages

- `SendMessage(delay=300s)`: store with `visible_at = now + 300s` in a **delay index** instead of the ready index.
- Short delays: an in-memory timing wheel per partition (persisted via the log).
- Long delays (hours/days): a tiered approach. Messages far in the future live on disk in an index sorted by `visible_at`; a background task loads those due in the next few minutes into the in-memory wheel.
- Same mechanism implements **retry backoff** (on failure, the consumer changes visibility to `backoff(attempt)`).

## 8. Deep dive: FIFO queues with message groups

- Ordering is required per **group_id**, not across the whole queue. Route by `hash(group_id) → partition`, so a group lives in exactly one partition.
- Within a partition, deliver **at most one in-flight batch per group**: if group G has an in-flight message, the next G message is not delivered until the first is deleted (or times out). Other groups proceed. That's the "head-of-line blocking per group only" property. Throughput scales with the number of active groups.
- **Send-side dedup:** keep `dedup_id → message_id` for 5 minutes per queue (in the partition's state, or a dedup table). A duplicate send within the window returns the original message ID without enqueuing.
- A failed message blocks its group until retries are exhausted and it moves to the DLQ (by design: ordering over progress).

## 9. Deep dive: scaling a hot queue

- **Standard queues:** partitions are interchangeable, so scale by adding partitions; the front end spreads sends across them. Receives sample several partitions (or the front end keeps a per-partition "has messages" hint) to avoid hammering empty ones.
- **Auto-split:** when a partition exceeds throughput or size thresholds, split it (new messages go to the new partitions; old ones drain). The metadata service records the new mapping.
- **Front-end caching** of the queue → partitions map, with versioned invalidation.
- **Empty receives are the hidden cost:** long polling with a per-partition notification (the waiting request parks on the partition until a message arrives or the wait expires) avoids busy polling across many partitions.

## 10. Deep dive: multi-tenancy and fairness

- Per-account and per-queue **rate limits** at the front end (token buckets).
- Partitions of different tenants share storage nodes; **placement** spreads big queues across nodes, and **shuffle sharding** limits the blast radius of a noisy tenant.
- Inside one queue shared by many sub-tenants (a common follow-up): the queue can't tell them apart, so recommend a queue per tenant, or a fair-dequeue layer (round-robin across per-tenant sub-queues).

## 11. Failure modes

| Failure | Handling |
|---|---|
| Partition leader crashes | A replica with the full log becomes leader (Raft election / metadata service). It replays the log to rebuild indexes. In-flight messages keep their `visible_at` (it was logged), so some may be redelivered early or late, never lost. |
| AZ loss | Each partition has replicas in 3 AZs; quorum survives. |
| Front-end node dies | Stateless; clients retry against another (sends must be safe to retry: client-supplied dedup ID, or accept rare duplicates in Standard queues). |
| Consumer crashes | Visibility timeout → redelivery → eventually DLQ if it keeps failing. |
| Consumer slower than the timeout | Duplicate concurrent processing. Extend visibility (heartbeat); attempt-fenced deletes. |
| Massive backlog (consumers down) | Storage sized for backlog; alarms on age of the oldest message; sends throttled if a tenant exceeds its storage quota. |
| Metadata service down | Front ends use cached routing; data path continues; only queue creation and rebalancing pause (**static stability**). |
| Clock skew | `visible_at` is computed and compared only by the partition leader's clock (a single clock per partition). After failover, the new leader's clock may differ slightly, causing small early/late redeliveries, which is acceptable for at-least-once. |

## 12. Observability

Queue depth (visible, in-flight, delayed), **age of oldest message**, send/receive/delete rates, empty-receive ratio, DLQ depth, per-partition latency and skew, replication lag.

## 13. Follow-ups

- **Large messages:** bodies over 256 KB go to a blob store; the queue holds a pointer, and the blob is garbage-collected after delete or retention.
- **Priority:** separate queues per priority with weighted receive at the client, or a priority-aware ready index (a heap per priority level) inside each partition.
- **Pub/sub on top:** a topic service that, on publish, enqueues into each subscriber queue (SNS → SQS).
- **How would you test it?** Jepsen-style fault injection (partition the leader, kill nodes, skew clocks) while checking invariants: no acknowledged send is lost; no message is delivered to two consumers while invisible; FIFO order per group holds.
- **Compare to Kafka:** Kafka's per-partition offset model can't give per-message visibility timeouts without blocking the partition; this design tracks per-message state instead, trading Kafka's simplicity and replay for independent acks.
