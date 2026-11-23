# Message Queues and Streaming

## Why use async messaging

- **Decoupling:** producers don't need consumers to be up
- **Load leveling:** absorb spikes; consumers process at their own rate
- **Fan-out:** one event, many consumers
- **Reliability:** retries, durable buffering
- **Ordering and replay** (log-based systems)

**Costs:** eventual consistency, harder debugging, duplicate handling, ordering complexity, another system to operate, and **hidden latency** (queue lag).

## Two families

### Message queues (traditional brokers)
- Message is consumed and **deleted** (acked). Competing consumers share work.
- Per-message acks, visibility timeouts, redelivery, dead-letter queues.
- Examples: **RabbitMQ, ActiveMQ, AWS SQS, Google Cloud Tasks**.
- Good for: **task/job queues**, work distribution, RPC-style async work.

### Log-based streams
- Append-only, **partitioned, replicated log**. Messages are retained (by time or size) regardless of consumption.
- Consumers track **offsets**; can **replay**; many independent consumer groups.
- Order is guaranteed **within a partition**.
- Examples: **Kafka, AWS Kinesis, Apache Pulsar, Redpanda, Google Pub/Sub** (hybrid).
- Good for: **event streaming, CDC, event sourcing, analytics pipelines, high-throughput fan-out**.

| | Queue (SQS/RabbitMQ) | Log (Kafka) |
|---|---|---|
| Consumption | Destructive (delete on ack) | Non-destructive (offset) |
| Replay | No (except DLQ) | Yes |
| Ordering | None (SQS standard) / FIFO groups | Per partition |
| Parallelism | Any number of consumers | ≤ number of partitions per consumer group |
| Per-message ack/retry | ✅ Native | ❌ Offset-based; one slow/poison message blocks the partition |
| Throughput | Medium–high | Very high |
| Fan-out | Via exchanges/SNS | Multiple consumer groups natively |
| Delayed messages | ✅ (SQS delay, RabbitMQ plugins) | ❌ Not native |
| Priority | ✅ RabbitMQ | ❌ (separate topics) |

## Kafka internals (frequently probed)

### Structure
- **Topic** → **partitions** (ordered, append-only logs) → **segments** on disk.
- Each partition has a **leader** and **followers** (replication factor, e.g., 3).
- **Producers** choose the partition: by key hash (same key → same partition → ordered), round-robin/sticky if keyless.
- **Consumer groups:** each partition is assigned to **exactly one consumer** in a group. Parallelism = number of partitions.

### Why Kafka is fast
- **Sequential disk I/O** (append-only)
- **OS page cache** (doesn't manage its own cache)
- **Zero-copy** (`sendfile`) from page cache to socket
- **Batching and compression** (producer batches, compressed batches stored as-is)
- **Partitioning** for parallelism

### Replication and durability
- **ISR (In-Sync Replicas):** followers caught up within `replica.lag.time.max.ms`.
- **`acks`:**
  - `acks=0`: fire and forget
  - `acks=1`: leader wrote it (lost if the leader dies before replication)
  - `acks=all`: all ISR have it. With `min.insync.replicas=2` (RF=3), it survives one broker failure without loss.
- **High watermark:** consumers only read up to the offset replicated to all ISR.
- **`unclean.leader.election.enable=false`:** never elect an out-of-sync replica (prefers unavailability over data loss).
- **Leader epoch** fences stale leaders and fixes log divergence after failover.
- **KRaft** (Kafka 3.3+ production-ready, ZooKeeper removed in 4.0): metadata managed by a Raft quorum of controllers.

### Consumer semantics
- **Commit offset after processing** → at-least-once (crash between process and commit = reprocessing).
- **Commit before processing** → at-most-once.
- **Exactly-once:** transactions (consume-transform-produce within Kafka) or storing offsets with results atomically.
- **Rebalancing:** when consumers join or leave, partitions are reassigned. Historically stop-the-world; **cooperative incremental rebalancing** and **static membership** reduce disruption.
- **Consumer lag** = latest offset − committed offset. **The key metric to monitor.**

### Partition count trade-offs
- More partitions → more parallelism, but more open files, longer leader elections, more memory, and longer rebalances.
- You **can't reduce** partitions, and increasing them **breaks key → partition mapping** (ordering for existing keys changes). Over-provision up front (e.g., 2–3× expected consumer count).

### Poison messages and retries in Kafka
A message that always fails blocks its partition. Patterns:
- **Retry topics** with delays (`orders.retry.1m`, `orders.retry.10m`) → **DLQ** after N attempts (Uber's pattern)
- Careful: moving a message to a retry topic **breaks per-key ordering**. If order matters, block that key (park subsequent messages for that key).

### Log compaction
Keep only the **latest value per key** (tombstone = null value deletes). Turns a topic into a durable changelog/table. Used for Kafka Streams state stores and `__consumer_offsets`.

## SQS specifics
- **Standard:** at-least-once, best-effort ordering, nearly unlimited throughput.
- **FIFO:** exactly-once processing within a 5-minute dedup window (dedup ID), ordered per **message group ID**; ~300 TPS per group, higher with batching and high-throughput mode.
- **Visibility timeout:** a received message is hidden for N seconds; if not deleted in time, it reappears (so set it above max processing time, or extend it via heartbeat).
- **DLQ** via redrive policy after `maxReceiveCount`.
- Long polling (`WaitTimeSeconds=20`) reduces empty receives and cost.

## RabbitMQ specifics
- AMQP: **exchanges** (direct, topic, fanout, headers) route to **queues** via bindings.
- Push-based with **prefetch** (QoS) limits for backpressure.
- Quorum queues (Raft) for durability.
- Good for complex routing, priorities, and per-message TTLs.

## Pub/Sub patterns

- **Fan-out:** SNS → multiple SQS queues; Kafka multiple consumer groups.
- **Topic-based routing:** RabbitMQ topic exchanges (`order.*.created`).
- **Competing consumers:** multiple workers on one queue.
- **Request-reply over a queue:** reply-to queue + correlation ID (rarely ideal).

## Backpressure and flow control

- Producers outpacing consumers → lag grows. With a log, the data is retained, so this is OK up to the retention limit.
- **Autoscale consumers on lag** (KEDA on Kubernetes).
- Bounded in-memory buffers in consumers.
- For queue-based systems, rate-limit producers or shed load at ingress.

## Delivery guarantees summary

| Guarantee | How |
|---|---|
| At-most-once | Ack/commit before processing |
| At-least-once | Ack/commit after processing; retries |
| Effectively exactly-once | At-least-once + idempotent consumer, or Kafka transactions within Kafka |

## Choosing

| Need | Pick |
|---|---|
| Background jobs, simple work queue, AWS | SQS (+ DLQ) |
| Complex routing, priorities, per-message TTL | RabbitMQ |
| High-throughput event streaming, replay, multiple consumers, CDC | Kafka (or Kinesis/Pulsar/Redpanda) |
| Strict ordering per entity | Kafka (key = entity) or SQS FIFO (group = entity) |
| Delayed/scheduled delivery | SQS delay (≤15 min), a scheduler service, Redis sorted set, RabbitMQ delayed exchange |
| Multi-tenant, geo-replication built in, tiered storage | Pulsar |
| Mobile/browser push | Not a broker. Use APNs/FCM + WebSocket gateway |
