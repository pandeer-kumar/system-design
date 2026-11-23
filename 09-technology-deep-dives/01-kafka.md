# Kafka Internals: A Deep Dive

> Interviewers at FAANG rarely accept "we'll put it on Kafka." They ask *why* ordering holds, *what* happens when a broker dies mid-write, *how* exactly-once works, and *what* you'd tune. This chapter is the depth behind those answers. For the "design Kafka from scratch" interview, see [case study 10](../06-case-studies/10-message-queue.md).

## 1. Mental model

Kafka is a **distributed, partitioned, replicated commit log**.

```
Topic "orders"
 ├── Partition 0: [0][1][2][3][4][5][6] ...  ← append-only, ordered, immutable
 ├── Partition 1: [0][1][2][3] ...
 └── Partition 2: [0][1][2][3][4] ...
Each partition: 1 leader + N-1 followers on different brokers (RF = N)
```

Five facts to anchor everything:

1. **Ordering exists only within a partition.** There's no global order across partitions.
2. **Messages aren't deleted on consumption.** Retention is time- or size-based (or compaction). Consumers track their own **offset**.
3. **All reads and writes for a partition go to its leader** (followers can serve reads with KIP-392 rack-aware fetching, but writes always go to the leader).
4. **Parallelism = partitions.** In a consumer group, each partition is consumed by exactly one member.
5. **Durability comes from replication, not fsync.** Kafka writes to the OS page cache and relies on replicas for safety.

## 2. Storage layer

### On-disk layout
```
/var/kafka-logs/orders-0/
  00000000000000000000.log        ← record batches (the data)
  00000000000000000000.index      ← sparse offset → byte position
  00000000000000000000.timeindex  ← sparse timestamp → offset
  00000000000005367851.log        ← next segment (name = base offset)
  00000000000005367851.index
  ...
  leader-epoch-checkpoint
```

- A partition is a sequence of **segments** (default 1 GB, `log.segment.bytes`). Only the last (**active**) segment receives writes.
- The **index is sparse** (one entry every `index.interval.bytes` ≈ 4 KB). A lookup is a binary search in the index, then a short sequential scan.
- **Retention deletes whole segments** (`retention.ms`, `retention.bytes`). That's O(1) file deletion, with no per-message cleanup.

### Record batches

- Producers send **batches**; the broker stores batches **as-is**, still compressed (compression happens once, at the producer).
- A batch header holds the base offset, producer ID, producer epoch, base sequence, transactional flag, and CRC.

### Why it's fast

| Technique | Effect |
|---|---|
| Sequential append-only writes | Disk throughput near sequential bandwidth even on HDD |
| OS page cache (no app-level cache) | Recently written data is served from memory; no double buffering, no GC pressure |
| Zero-copy (`sendfile`) | Page cache → socket without copying into user space (disabled with TLS, which needs encryption in user space) |
| Batching + compression end to end | Fewer, larger I/Os and network packets |
| Partitioning | Horizontal parallelism across brokers and disks |

### Log compaction

- `cleanup.policy=compact`: keep at least the **latest record per key**. Older records with the same key are removed by the background log cleaner.
- **Tombstone** = a record with a `null` value. It deletes the key after `delete.retention.ms`.
- The cleaner only touches the "dirty" (uncompacted) portion; `min.cleanable.dirty.ratio` controls how often.
- Use cases: changelogs (CDC), Kafka Streams state store backups, `__consumer_offsets`, configuration topics. A compacted topic is effectively a **table** that you can rebuild by reading from offset 0.

### Tiered storage (KIP-405, production-ready in 3.9)

- Old segments are offloaded to object storage (S3/GCS); brokers keep only the recent tail on local disk.
- Retention can be months or years cheaply, and broker rebalancing moves far less data.

## 3. The producer, in detail

```
send(record) → serializer → partitioner → RecordAccumulator (per-partition batches)
             → Sender thread → groups batches by leader broker → ProduceRequest
```

### Partitioning

- **Keyed:** `murmur2(key) % numPartitions`, so the same key always lands in the same partition (as long as the partition count doesn't change).
- **Keyless:** the **sticky partitioner** (since 2.4) fills a batch for one partition before switching, which gives bigger batches and lower latency than round-robin.
- A custom partitioner is useful for hot keys (e.g., spreading one huge tenant across sub-partitions).

### Batching knobs

| Setting | Meaning | Trade-off |
|---|---|---|
| `batch.size` (16 KB default) | Max bytes per partition batch | Bigger = throughput, more memory |
| `linger.ms` (5 ms default in 4.0; 0 before) | Wait to fill a batch | Higher = throughput, more latency |
| `compression.type` | `lz4`/`zstd`/`snappy`/`gzip` | zstd best ratio, lz4 fastest; huge win on JSON |
| `buffer.memory` | Total accumulator memory | When full, `send()` blocks for `max.block.ms` (backpressure) |

### Durability knobs

| Setting | Meaning |
|---|---|
| `acks=0` | Don't wait. Fastest, may lose data. |
| `acks=1` | Leader wrote it to its log. Lost if the leader dies before followers copy it. |
| `acks=all` (default since 3.0) | All **current ISR members** have it. |
| `min.insync.replicas` (topic/broker) | With `acks=all`, reject the write if the ISR is smaller than this. **RF=3 + min.insync=2** is the standard durable setup: tolerates 1 broker loss with no data loss and no write outage. |
| `retries`, `delivery.timeout.ms` | Retry transient errors until the delivery timeout (2 min default) |

### Idempotent producer (default since 3.0)

- The broker assigns a **producer ID (PID)**; the producer numbers each batch per partition with a **sequence number**.
- The broker keeps the last 5 sequence numbers per (PID, partition). A retried duplicate is acknowledged but not appended again; a gap returns `OutOfOrderSequence`.
- That's why `max.in.flight.requests.per.connection ≤ 5` **keeps ordering** even with retries.
- Scope: per producer session and partition. A restarted producer gets a new PID, unless it's transactional (see §7).

## 4. The broker and replication protocol

### Request handling

- **Network threads** (`num.network.threads`) read requests from sockets into a request queue.
- **I/O threads** (`num.io.threads`) process requests (append to log, read).
- **Purgatory:** requests that must wait (an `acks=all` produce waiting for replication, a fetch waiting for `fetch.min.bytes`) are parked in a timer wheel until satisfied or timed out.

### Replication: LEO, HW, ISR

- **LEO (log end offset):** the next offset each replica will write.
- **Followers fetch** from the leader exactly like consumers (pull-based replication), and report their LEO in each fetch.
- **High watermark (HW)** = min LEO across the ISR. Records below the HW are **committed**. Consumers can read only up to the HW (so they never see data that could vanish on failover).
- **ISR (in-sync replicas):** replicas that have caught up within `replica.lag.time.max.ms` (30 s). A follower that falls behind is removed from the ISR; it rejoins when caught up. ISR changes are recorded in the controller's metadata.

```
Leader   LEO=10   [0..9]
F1       LEO=10   [0..9]      ISR = {L, F1, F2}
F2       LEO=8    [0..7]      HW = 8 → consumers see offsets 0..7
```

### Why ISR rather than majority quorum?

- A majority quorum with RF=3 tolerates 1 failure. ISR with RF=3 and `min.insync.replicas=2` also tolerates 1 failure **without data loss**, but as long as ISR ≥ 1 and you allow it, it can keep serving reads with a single replica.
- The real difference: Kafka moves the **"who is in sync" decision** into a consensus-backed controller, so the data path only needs leader → followers, without a quorum vote per record.

### Leader election and the leader epoch

- When a leader dies, the controller picks a new leader **from the ISR** (preferring the "preferred replica"). Every leadership change increments the **leader epoch**.
- **Truncation problem:** the HW alone can't safely decide what a recovering replica should truncate. Data can be lost or diverge (KIP-101 fixed real bugs here).
- **Fix:** on recovery, a follower asks the leader "what was the end offset of epoch N?" and truncates to that point. The leader epoch acts as a **fencing token** for log history.
- `unclean.leader.election.enable=false` (default): never elect a replica outside the ISR. **Prefer unavailability to data loss.** Setting it to `true` trades acknowledged data for availability.

### KRaft (controller quorum)

- Kafka 4.0 removed ZooKeeper. A **Raft quorum of controllers** (3 or 5 nodes) stores cluster metadata as a replicated log: `__cluster_metadata`.
- Brokers **fetch** metadata updates from the controller (like followers), so propagation is incremental and fast, and the cluster supports millions of partitions.
- **Broker liveness:** brokers heartbeat to the active controller; a broker that misses heartbeats is **fenced**, and leadership moves off it.
- **Controller epoch / broker epoch** fence stale controllers and zombie brokers.
- This is the general pattern: **consensus for metadata, simple replication for data.**

### Rack awareness
`broker.rack` makes replica placement spread across AZs, so RF=3 survives an AZ loss. Consumers can use `client.rack` to fetch from a follower in the same AZ (KIP-392), which cuts cross-AZ data transfer cost.

## 5. Consumers and consumer groups

### Offsets

- Consumers commit offsets to the internal compacted topic `__consumer_offsets`, keyed by (group, topic, partition).
- The committed offset is "the next record to read," not "the last record processed."
- `enable.auto.commit=true` commits periodically **in the background**, regardless of whether processing finished. That's at-most-once or at-least-once depending on timing. **Use manual commits** after processing for correctness.
- `auto.offset.reset=earliest|latest` applies only when there's no committed offset.

### Group membership and rebalancing

- A **group coordinator** (a broker, chosen by hashing the group ID onto a `__consumer_offsets` partition) manages membership.
- Consumers send **heartbeats** (background thread) and must call `poll()` within `max.poll.interval.ms` (5 min). Breaking either rule gets them kicked out, which triggers a rebalance.

**Classic protocol** (JoinGroup → SyncGroup):

1. All members re-join; the coordinator picks a leader member.
2. The leader runs the **assignor** and sends the assignment back via SyncGroup.

| Assignor | Behaviour |
|---|---|
| Range | Per topic, contiguous ranges. Can be uneven across topics. |
| RoundRobin | Even, but reshuffles everything on change |
| Sticky | Keeps prior assignments where possible |
| **CooperativeSticky** | Incremental: only partitions that must move are revoked. **No stop-the-world pause.** |

**New consumer protocol (KIP-848, GA in Kafka 4.0):** the **broker** computes assignments and reconciles them incrementally. There's no group-wide synchronization barrier, so rebalances are faster and less disruptive.

**Static membership** (`group.instance.id`): a member that restarts within `session.timeout.ms` gets its old partitions back without a rebalance. Essential for rolling deploys of stateful consumers.

### Zombie consumers
A consumer pauses (GC) longer than the session timeout. Its partitions are reassigned, but it wakes up and tries to commit. The commit is rejected because the **generation ID** (group epoch) is stale. This is a fencing token again. However, the zombie may already have **produced side effects** (a DB write), which is why processing must be idempotent.

### Processing patterns

| Pattern | Semantics |
|---|---|
| poll → commit → process | At-most-once |
| poll → process → commit | **At-least-once** (the default you should assume) |
| poll → process → write result + offset in one DB transaction; on start, seek to the stored offset | Exactly-once effect into that DB |
| consume → transform → produce with transactions | Exactly-once within Kafka |

**Parallelism inside a partition:** if one partition is a bottleneck, process records in parallel **by key** inside the consumer (e.g., Confluent Parallel Consumer), tracking which offsets are safe to commit. That keeps per-key ordering.

## 6. Ordering guarantees, precisely

| Situation | Ordered? |
|---|---|
| Same key, same partition, idempotent producer | ✅ |
| Same key, after increasing the partition count | ❌ (key → partition mapping changes) |
| Non-idempotent producer, retries, `max.in.flight > 1` | ❌ (batch 2 can land before retried batch 1) |
| Consumer processing a partition with a thread pool | ❌ unless parallelized by key |
| Moving a failed message to a retry topic | ❌ for that key (later messages overtake it) |
| Across partitions | Never guaranteed |

**Choose the partition key = the unit that needs ordering** (order_id, account_id, user_id). If two entities must be ordered relative to each other, they need the same key.

## 7. Exactly-once semantics (EOS) internals

Pieces:

1. **Idempotent producer** (§3) removes duplicates from producer retries.
2. **Transactions** make writes to multiple partitions, **plus the consumer offset commit**, atomic.
3. **`isolation.level=read_committed`** consumers don't see aborted or still-open transactional data.

Protocol:
```
producer.initTransactions()            → transaction coordinator (by hashing transactional.id)
                                          bumps the producer epoch → FENCES any older instance with the same transactional.id
producer.beginTransaction()
producer.send(...) to partitions A, B   → coordinator records A, B in the transaction log (__transaction_state)
producer.sendOffsetsToTransaction(...)  → the consumer offsets become part of the transaction
producer.commitTransaction()            → coordinator writes PREPARE_COMMIT to its log (point of no return),
                                          then writes COMMIT markers into A, B and the offsets partition,
                                          then COMPLETE_COMMIT
```

- It's a **2PC whose coordinator log is itself a replicated Kafka partition**, so it doesn't have classic 2PC's blocking problem.
- **Last stable offset (LSO):** `read_committed` consumers can't read past the first still-open transaction, so a long transaction stalls downstream consumers. Keep transactions short (`transaction.timeout.ms`).
- **Zombie fencing:** the epoch bump on `initTransactions` means an old instance of the same `transactional.id` gets `ProducerFencedException`.
- **Limits:** EOS covers Kafka → Kafka. Writing to an external DB or calling an API needs idempotency there. Kafka Streams and Flink wrap this for you (`processing.guarantee=exactly_once_v2`).
- **Cost:** a few percent of throughput for reasonable transaction sizes, plus added end-to-end latency (commit interval).

## 8. Sizing and performance

**Partition count:**
```
partitions ≥ max(target_throughput / per-partition_producer_throughput,
                 target_throughput / per-partition_consumer_throughput,
                 desired consumer parallelism)
```

- Rule of thumb: plan ~10 MB/s per partition and size for 2–3 years of growth, because you can't shrink partitions and adding them breaks key ordering.
- Too many partitions cost memory, file handles, longer leader elections, and slower rebalances. (KRaft clusters handle far more partitions than ZooKeeper-based ones did.)

**Ballpark numbers:** a single broker on modern hardware sustains hundreds of MB/s in and out; end-to-end latency is typically low single-digit ms at moderate load with `linger.ms` ≈ 5, and p99 tens of ms under heavy load.

**Throughput vs latency tuning:**

| Goal | Producer | Consumer | Broker/topic |
|---|---|---|---|
| Throughput | `linger.ms` 10–100, `batch.size` 64K–1M, zstd/lz4 | `fetch.min.bytes` large, `max.poll.records` large | More partitions |
| Latency | `linger.ms` 0–5, small batches | `fetch.max.wait.ms` small | Fewer hops; avoid TLS overhead if possible |
| Durability | `acks=all`, idempotence | Manual commit after processing | RF=3, `min.insync.replicas=2`, unclean election off |

## 9. Failure scenarios (be able to walk through these)

| Scenario | What happens | Data loss? |
|---|---|---|
| Leader broker crashes | Controller fences it (missed heartbeats), elects a new leader from the ISR; clients refresh metadata and retry | No (with `acks=all`, min ISR 2) |
| Follower slow | Removed from ISR after 30 s; writes continue if ISR ≥ min.insync | No |
| ISR shrinks below min.insync | `acks=all` produces fail with `NotEnoughReplicas`; reads continue | No (availability lost instead) |
| All ISR replicas die, only an out-of-sync replica remains | Partition offline (unclean election disabled) | No, but unavailable |
| Leader partitioned from the cluster but alive | It can't get ISR acks; the controller elects a new leader; the old one is fenced by epoch | No |
| `acks=1` and the leader dies right after acking | New leader lacks the record | **Yes** |
| Consumer crashes after processing, before committing | Redelivery from the last committed offset | Duplicates |
| Consumer stuck (poll interval exceeded) | Kicked from the group; partitions reassigned; its later commits fail | Duplicates possible |
| Poison message | Consumer fails repeatedly on the same offset; the partition stalls | Stalled unless you skip/DLQ |
| Consumer lag exceeds retention | Old segments deleted before being consumed | **Yes** (silent!) — alert on lag vs retention |
| Disk full on a broker | Broker stops; partitions fail over | Monitor disk; use tiered storage |
| Whole AZ lost (rack-aware RF=3) | Leaders move to surviving AZs | No |
| Whole region lost | Kafka clusters are regional; you need MirrorMaker 2 / Cluster Linking to another region, with async lag | Possibly the replication lag |

## 10. Operations essentials

- **Monitor:** under-replicated partitions (should be 0), offline partitions, ISR shrink/expand rate, request latency (produce/fetch p99), **consumer lag (records and time)**, disk usage, controller health, network handler idle %.
- **Rebalancing partitions** across brokers: `kafka-reassign-partitions` or Cruise Control, with throttles (it competes with production traffic).
- **Rolling upgrades:** one broker at a time; wait for under-replicated partitions to reach 0 between brokers.
- **Quotas:** per-client byte-rate and request quotas protect the cluster from noisy clients.
- **Multi-region:** MirrorMaker 2 (offset translation via checkpoints), Confluent Cluster Linking (byte-for-byte mirroring, offsets preserved). Topologies: active-passive DR, or regional clusters aggregated into a central one.
- **Schema management:** a Schema Registry with Avro/Protobuf and compatibility rules (backward compatible by default).

## 11. Patterns built on Kafka

| Pattern | How |
|---|---|
| Transactional outbox / CDC | Debezium reads the DB WAL → Kafka topic per table, keyed by PK |
| Event sourcing | One topic partitioned by aggregate ID; snapshots in a compacted topic |
| Materialized views | Kafka Streams / Flink aggregate a stream into a state store (RocksDB, backed up to a compacted changelog topic) |
| Stream–table join | KTable (compacted topic) enriches a KStream |
| Retry with delay | Retry topics per delay tier (`orders.retry.1m`, `.10m`) + DLQ (Uber's pattern) |
| Request fan-out | Many consumer groups on one topic |
| Log aggregation / metrics pipeline | Agents → Kafka → storage sinks (Kafka Connect) |

## 12. Anti-patterns

- **Kafka as a task queue with per-message retries, priorities, or delays.** It lacks those natively. Use SQS/RabbitMQ, or Kafka's share groups (KIP-932, early access in 4.0) once mature.
- **A topic per user/entity** (millions of topics). Use keys.
- **Very large messages** (over 1 MB by default). Store the payload in S3 and send a reference (claim-check pattern).
- **Using Kafka as a database for point lookups by key.** Materialize into a real store.
- **Auto-commit with slow, side-effecting processing.**
- **Too few partitions for future consumer parallelism.**

## 13. Kafka vs alternatives

| | Kafka | Pulsar | Kinesis | Redpanda | Google Pub/Sub | RabbitMQ Streams |
|---|---|---|---|---|---|---|
| Model | Partitioned log | Log with separate storage (BookKeeper) | Shards | Kafka API, C++, Raft per partition | Managed, per-message ack | Log in RabbitMQ |
| Ops | Self-managed or MSK/Confluent | More components | Fully managed | Simpler (single binary) | Fully managed | Part of RabbitMQ |
| Strength | Ecosystem, throughput | Multi-tenancy, geo-replication, tiered storage | AWS integration | Latency, simplicity | Serverless scaling | Mixing queues and streams |
| Watch out | Partition planning, ops | Complexity | Shard limits (1 MB/s in per shard) | Smaller ecosystem | Ordering only with ordering keys | Scale ceiling |

## 14. Interview questions on Kafka (with crisp answers)

1. **How does Kafka guarantee ordering?** Per partition only. Same key → same partition (murmur2 hash), idempotent producer keeps order across retries, one consumer per partition in a group.
2. **What's the ISR and why `min.insync.replicas=2`?** Replicas caught up within the lag window. `acks=all` waits for the ISR; min ISR 2 ensures every acknowledged write exists on at least 2 brokers.
3. **What's the high watermark?** The min LEO across ISR; consumers see only committed records below it.
4. **Why the leader epoch?** The HW alone can't safely determine truncation after failover; the epoch tells a recovering replica exactly where its history diverged.
5. **How does exactly-once work?** Idempotent producer (PID + sequence), transactions with a replicated coordinator log and commit markers including the offset commit, and `read_committed` consumers. It applies within Kafka only.
6. **Consumer crashed after processing but before committing. What happens?** The message is redelivered; consumers must be idempotent.
7. **How do you handle a poison message?** Catch, send to a retry topic with backoff, then a DLQ after N attempts; alert. If per-key ordering matters, park the key.
8. **How many partitions?** Throughput ÷ per-partition throughput, at least the max consumer parallelism, sized for growth; adding later breaks key mapping.
9. **What causes rebalance storms, and how do you fix them?** Slow processing exceeding `max.poll.interval.ms`, frequent deploys. Fix with cooperative-sticky assignment or KIP-848, static membership, smaller `max.poll.records`, and timeouts sized to processing time.
10. **Can Kafka lose data?** Yes: `acks=1` or `acks=0`, unclean leader election, consumer lag beyond retention, `min.insync.replicas=1` with RF=3 when the single replica dies, or fsync-less writes if every replica crashes at once (e.g., an AZ power failure with all replicas in one AZ).
11. **Why is Kafka fast?** Sequential I/O, page cache, zero-copy, batching and compression end to end, partitioned parallelism.
12. **How does Kafka scale reads to many consumer groups?** Every group reads the same log independently with its own offsets; data stays in the page cache for recent reads; follower fetching (KIP-392) spreads load.
13. **Why did Kafka remove ZooKeeper?** Metadata scalability (millions of partitions), faster controller failover (the metadata log is already replicated in the controllers), and one system to operate.
14. **Kafka vs SQS for background jobs?** SQS: per-message visibility timeout, ack, delay, DLQ, no partition planning. Kafka: replay, ordering per key, multiple consumers, much higher throughput. For a job queue, SQS (or RabbitMQ) is usually the better fit.
