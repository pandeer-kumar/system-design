# Case Study 10: Distributed Message Queue (design Kafka)

> Tests: log-structured storage, partitioning, replication with leaders and ISR, consumer groups and offsets, ordering, delivery semantics, and controller/consensus design.

## 1. Requirements

**Functional**
- Producers publish messages to topics
- Consumers subscribe; multiple independent consumer groups
- Ordering within a partition (by key)
- Retention by time/size; replay from any offset
- Optional: exactly-once semantics, log compaction

**Non-functional**
- Throughput: millions of msgs/s, GB/s per cluster
- Durability: no loss of acknowledged messages with up to f broker failures
- Low latency: ~ms end-to-end
- Horizontal scalability; high availability

## 2. Core abstraction: the partitioned log

```
Topic "orders" (3 partitions, RF=3)
  P0: [m0 m1 m2 m3 m4 ...]   leader B1, followers B2,B3
  P1: [m0 m1 m2 ...]         leader B2, followers B3,B1
  P2: [m0 m1 ...]            leader B3, followers B1,B2
```
- A message has an **offset** (its position in the partition).
- Producers append to partition leaders; consumers read sequentially by offset.
- **Consumption doesn't delete.** Retention is independent of consumption.

## 3. Storage on a broker

- Each partition = a directory of **segment files** (e.g., 1 GB each): `00000000000000000000.log`, plus a sparse **offset index** and a **time index**.
- Append-only writes go to the OS page cache (and are flushed by the OS or on a policy). **Durability comes from replication**, not from fsync on every message.
- Reads: binary search the index for the offset → sequential read → **zero-copy** `sendfile` to the socket.
- Retention: delete whole old segments (cheap). Compaction: rewrite segments keeping the latest value per key.
- **Tiered storage:** old segments offloaded to S3; brokers keep only the recent tail locally.

## 4. Producer

- Partition choice: `hash(key) % partitions` (same key → same partition → ordered), or sticky/round-robin for keyless messages.
- **Batching** (`linger.ms`, `batch.size`) + compression = high throughput.
- `acks=all` + `min.insync.replicas=2` for durability.
- **Idempotent producer:** producer ID + per-partition sequence numbers let the broker dedupe retries and keep ordering even with multiple in-flight requests.

## 5. Replication (deep dive)

- Each partition has one **leader** and N−1 **followers**. Followers **pull** from the leader (like consumers).
- **ISR (in-sync replicas):** replicas caught up within `replica.lag.time.max.ms`. A lagging replica is removed from the ISR; it rejoins once caught up.
- **Commit point = high watermark (HW):** the highest offset replicated to all ISR members. Consumers only see messages ≤ HW.
- `acks=all` waits for every **current ISR** member. With `min.insync.replicas=2`, if the ISR shrinks to 1, writes are rejected (prefer unavailability to loss).

**Why ISR instead of a majority quorum?** With ISR, you tolerate N−1 failures with N replicas (vs. ⌊(N−1)/2⌋ with majority quorums), because the ISR membership itself is maintained by a consistent controller. The trade-off: ISR membership changes need a consistent metadata store.

**Leader failover:**
- The controller picks a new leader **from the ISR** (so no committed data is lost).
- **Leader epoch:** each new leadership increments an epoch. Followers truncate their logs to the leader's epoch boundaries on recovery (fixes divergence that the high watermark alone can't, a bug class found in early Kafka).
- `unclean.leader.election=false`: never elect an out-of-ISR replica (that would lose data).

## 6. Controller and metadata

- Metadata: topics, partitions, leaders, ISR, configs, broker liveness.
- Historically ZooKeeper; now **KRaft**: a Raft quorum of controller nodes stores the metadata log; brokers fetch metadata updates from it.
- The controller detects broker failure (session/heartbeat timeout) and reassigns partition leadership. **Controller epoch** fences stale controllers.
- **Keep consensus on the control plane and simple replication on the data plane.** This is the key architectural insight.

## 7. Consumers and consumer groups

- A **consumer group** shares the work: each partition is assigned to exactly one consumer in the group (so ordering per partition is preserved).
- Parallelism ≤ number of partitions.
- **Offsets** are committed to an internal compacted topic (`__consumer_offsets`), keyed by (group, topic, partition).
- **Group coordinator** (a broker) manages membership via heartbeats; on join/leave/timeout, a **rebalance** reassigns partitions.
  - Eager rebalance: stop-the-world. Cooperative incremental: only moved partitions pause. Static membership: restarts within a timeout don't trigger a rebalance.
- **Zombie consumers:** a consumer paused past the session timeout loses its partitions; when it resumes, its commits are rejected (generation ID acts as a fencing token).

## 8. Delivery semantics

| Semantics | Configuration |
|---|---|
| At-most-once | Commit offset before processing |
| At-least-once | Process, then commit (default) |
| Exactly-once (Kafka→Kafka) | Idempotent producer + **transactions**: write output messages and the consumer offset commit atomically; downstream consumers use `read_committed` |
| Exactly-once to external sinks | Idempotent writes keyed by (topic, partition, offset), or store offsets in the sink transactionally |

**Transactions internals:** a transaction coordinator, a transactional ID (fences zombie producers by epoch), markers (commit/abort) written into partitions, and consumers with `read_committed` that skip aborted data and wait at the "last stable offset."

## 9. Ordering subtleties

- Ordering holds only **within a partition**.
- Increasing the partition count remaps keys, which breaks ordering for existing keys during the transition.
- Retries without idempotence can reorder (batch 1 fails, batch 2 succeeds, batch 1 retried). Idempotent producers fix this.
- Consumers processing in parallel within a partition lose order unless they parallelize **by key** inside the partition.

## 10. Design alternatives to discuss

- **Pull vs push:** Kafka uses pull. Consumers control their rate (natural backpressure), batching is easy, and replay is easy. Push (RabbitMQ) gives lower latency for small loads but needs prefetch limits.
- **Pulsar architecture:** separates serving (stateless brokers) from storage (Apache BookKeeper bookies). Easier scaling and rebalancing (no partition data movement), at the cost of more components.
- **Queue semantics on a log:** per-message acks and delays are awkward on a log. Kafka added "share groups" (queues for Kafka, KIP-932) for queue-like consumption.

## 11. Failure modes

| Failure | Behaviour |
|---|---|
| Leader broker dies | Controller elects a new leader from the ISR in seconds; producers/consumers refresh metadata |
| Follower slow | Drops out of the ISR; `acks=all` writes continue with the remaining ISR (if ≥ min.insync) |
| Network partition isolates the leader | Leader can't reach the ISR, so writes with `acks=all` fail; the controller moves leadership; leader epoch fences the old leader |
| Disk full | Retention policy, tiered storage, alerts on disk usage |
| Consumer lag explosion | Scale consumers (up to the partition count); alert on lag; retention must exceed the max lag |
| Poison message | Consumer-side retry topic + DLQ |

## 12. Follow-ups

- **How many partitions?** Target throughput / per-partition throughput (~10 MB/s per partition is a safe rule), ≥ max consumer parallelism, with headroom.
- **Delayed messages:** not native. Use time-bucketed topics or an external scheduler.
- **Multi-region:** MirrorMaker 2 / Cluster Linking (async replication); offsets differ across clusters (offset translation); active-passive or aggregate clusters.
