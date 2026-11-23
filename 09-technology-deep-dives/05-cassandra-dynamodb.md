# Cassandra and DynamoDB: A Deep Dive

> The two wide-column / key-value stores most often proposed for "massive scale, simple access patterns." Interviewers check that you can **model data for them**, know their **consistency knobs**, and avoid their **classic failure modes** (hot partitions, tombstones, large partitions). For the from-scratch design, see [case study 03](../06-case-studies/03-key-value-store.md).

## Part 1: Apache Cassandra (and ScyllaDB)

### Architecture recap
- **Leaderless**, peer-to-peer ring with consistent hashing and vnodes; any node can coordinate a request.
- Replication factor per keyspace and per datacenter (`NetworkTopologyStrategy`, e.g., `{us-east: 3, eu-west: 3}`), rack/AZ-aware placement.
- Gossip for membership; Phi accrual failure detection; hinted handoff; read repair; anti-entropy repair with Merkle trees.
- **ScyllaDB:** a C++ rewrite with the same data model and protocol; a **shard-per-core** architecture (each core owns its data, no locks, no JVM GC), giving several times higher throughput per node and more predictable latency (Discord's migration).

### Write path
```
coordinator → replicas (all RF, in parallel)
replica: append to commit log (sequential) → write to memtable (in memory, sorted) → ack
later:   memtable flush → immutable SSTable on disk
         compaction merges SSTables
```
Writes are **very cheap**: no read before write, no locking, sequential I/O. That's why Cassandra excels at write-heavy workloads (time series, messaging, event logs).

**Upserts:** every INSERT/UPDATE is a write of cells with timestamps. There's no "does it exist?" check, and the **last-write-wins by cell timestamp** rule resolves conflicts.

### Read path
```
coordinator → contact enough replicas for the consistency level (one full read + digests from others)
replica: row cache? → memtable → for each SSTable: Bloom filter → partition index (summary) → data
         merge cells across memtable + SSTables by timestamp → apply tombstones
coordinator: compare digests; mismatch → full reads → newest wins → read repair
```
Reads are more expensive than writes; they get slower as the number of SSTables per partition grows (compaction keeps this bounded).

### Consistency levels (per query)
| Level | Meaning |
|---|---|
| `ONE` / `TWO` / `THREE` | That many replicas respond |
| `QUORUM` | ⌊RF/2⌋+1 replicas across all DCs |
| **`LOCAL_QUORUM`** | Quorum within the coordinator's DC (the usual production choice) |
| `EACH_QUORUM` | Quorum in every DC (writes) |
| `ALL` | Every replica (one down replica fails the request) |
| `LOCAL_ONE` | One replica in the local DC |
| `SERIAL` / `LOCAL_SERIAL` | Paxos, for lightweight transactions |

`LOCAL_QUORUM` writes + `LOCAL_QUORUM` reads give read-your-writes within a DC (with the usual quorum caveats: not linearizable under concurrent or failed writes).

### Lightweight transactions (LWT)
- `INSERT ... IF NOT EXISTS`, `UPDATE ... IF balance = 100`: compare-and-set via **Paxos per partition** (4 round trips in the classic implementation; Cassandra 5 improves with Paxos v2, and Accord transactions are coming).
- Use them for **uniqueness** (claim a username, a seat) and occasional CAS, not on hot paths.

### Data modeling: query-first
**Rule:** one table per query pattern. Denormalize. Data duplication is expected.

```sql
-- Query: latest messages in a conversation
CREATE TABLE messages_by_conversation (
  conversation_id uuid,
  bucket int,                 -- e.g., yyyymm, to bound partition size
  message_id timeuuid,
  sender_id uuid,
  body text,
  PRIMARY KEY ((conversation_id, bucket), message_id)
) WITH CLUSTERING ORDER BY (message_id DESC);
```
- **Partition key** (inside the inner parentheses) decides placement; **clustering columns** decide sort order within the partition.
- Every query must specify the full partition key. Range filters only on clustering columns, in order.
- **Partition size guidance:** keep partitions under ~100 MB and ~100K rows. Unbounded partitions (all messages of a busy channel, all events of a device) cause slow reads, compaction pain, and repair problems. **Bucket by time.**
- **Secondary indexes** are local (scatter to all nodes) and usually a bad idea at scale; SAI (storage-attached indexes, Cassandra 5) improves this. Materialized views are discouraged (consistency bugs); maintain your own denormalized tables.

### Tombstones (the classic production trap)
- A delete writes a **tombstone**; it can't remove data immediately, because a replica that missed the delete could resurrect the old value during repair.
- Tombstones are purged after `gc_grace_seconds` (10 days default) **and** compaction. **Repair must run more often than gc_grace**, or deleted data can come back ("zombie data").
- Reading a partition with thousands of tombstones is slow; after `tombstone_failure_threshold` (100K) the query fails.
- **Anti-pattern: queues on Cassandra** (insert, read, delete in a cycle). Every dequeue leaves a tombstone, and reads scan them. Use a real queue.
- TTL'd data also produces tombstones; use **TimeWindowCompactionStrategy** so whole expired SSTables are dropped.

### Compaction strategies
| Strategy | Best for | Trade-off |
|---|---|---|
| SizeTiered (STCS) | Write-heavy | Up to 2× temporary disk space; more SSTables per read |
| Leveled (LCS) | Read-heavy, updates | More write amplification (I/O) |
| TimeWindow (TWCS) | Time series with TTL | Don't mix out-of-order writes or deletes |
| Unified (UCS, Cassandra 5) | Adaptive general purpose | Newer |

### Operating Cassandra
- Run **repair** regularly (incremental, or a tool like Reaper).
- Keep disk usage under ~50% with STCS (compaction needs room).
- JVM GC tuning matters (big source of latency spikes) → one reason for ScyllaDB.
- Adding nodes streams data (bootstrap); do it before you're full.
- Monitor: read/write latency p99, pending compactions, dropped mutations, hints, tombstones per read, partition size, GC pauses.

## Part 2: Amazon DynamoDB

### Architecture (from the 2022 USENIX paper)
- **Not** Dynamo-the-paper. DynamoDB is **leader-based**: each partition is a **replication group of 3 replicas across 3 AZs**, using **Multi-Paxos** for leader election; the leader handles writes and strongly consistent reads.
- **Request routers** look up partition metadata and forward requests; storage nodes hold B-tree data + replication logs.
- Writes are acknowledged after the leader and a quorum (2 of 3) persist the log record.
- Eventually consistent reads can be served by any replica (half the cost).

### Partitions and throughput
- Items are placed by **hash(partition key)**; within a partition, items with the same partition key are sorted by the **sort key** (an "item collection").
- Per-partition limits: **~3,000 read units/s, ~1,000 write units/s, ~10 GB**. A partition that exceeds them is split.
- 1 WCU = one write/s of up to 1 KB. 1 RCU = one strongly consistent read/s (or two eventually consistent) up to 4 KB. Transactions cost 2×.
- **Adaptive capacity** shifts throughput to hot partitions and **splits for heat** automatically, but **a single partition key value can't exceed the per-partition limits**. A single hot key (a celebrity's counter) still throttles. Write-shard it (`key#0..#N`).
- **On-demand** mode (pay per request, scales automatically, with sudden spikes absorbed up to ~2× the previous peak instantly) vs **provisioned** (cheaper at steady load, with auto scaling).

### Indexes
| | Local secondary index (LSI) | Global secondary index (GSI) |
|---|---|---|
| Keys | Same partition key, different sort key | Any partition and sort key |
| Consistency | Strong reads possible | **Eventually consistent only** (async propagation) |
| Created | Only at table creation | Any time |
| Limit | Item collection ≤ 10 GB per partition key | Own capacity; a throttled GSI **back-pressures table writes** |

### Single-table design
Store multiple entity types in one table with overloaded keys so that each access pattern is a single `Query`:
```
PK              SK                       data
CUSTOMER#42     PROFILE                  name, email
CUSTOMER#42     ORDER#2026-11-01#9001    total, status
CUSTOMER#42     ORDER#2026-11-20#9050    ...
ORDER#9001      ITEM#1                   sku, qty
GSI1PK=STATUS#PENDING  GSI1SK=2026-11-20#9050   (sparse index for "pending orders")
```
Start from the list of access patterns; design PK/SK and GSIs to satisfy each with one request. (Alex DeBrie's *The DynamoDB Book* is the reference.) Single-table design isn't mandatory; multiple tables are fine when patterns don't need joins.

### Concurrency features
- **Conditional writes:** `ConditionExpression` (e.g., `attribute_not_exists(pk)` for create-if-absent, `version = :v` for optimistic locking, `stock >= :qty` for safe decrements). This is the primary concurrency tool.
- **Atomic counters:** `UpdateExpression: ADD views :one` (not idempotent on retry!).
- **Transactions:** `TransactWriteItems` / `TransactGetItems`, up to 100 items across tables in one region, serializable, with optional idempotency via `ClientRequestToken` (10-minute window). Implemented with a transaction coordinator and timestamp ordering; costs 2×.
- **Idempotency:** conditional puts keyed by a request ID, or the `ClientRequestToken` for transactions.

### Streams and integrations
- **DynamoDB Streams:** an ordered, per-item change log (24 h retention), consumed by Lambda or the Kinesis adapter. Use for CDC, materialized views, search indexing, and the outbox pattern ("write the item, stream triggers the publish").
- **TTL:** free, background expiry of items (within ~a few days, not exact; deletions appear in the stream).

### Global tables
- Multi-region, **multi-active**, async replication (typically ~1 s), **last-writer-wins** conflict resolution. **Don't use them for uniqueness or invariants** that need cross-region coordination; route such writes to a home region. (AWS added a multi-region strong consistency option in 2025; it costs cross-region latency on writes.)

### DAX
An in-memory write-through cache in front of DynamoDB (µs reads). Eventually consistent; doesn't help strongly consistent reads.

### Limits to remember
Item size ≤ 400 KB (store blobs in S3); `Query`/`Scan` page ≤ 1 MB; batch write ≤ 25 items; transaction ≤ 100 items.

## Part 3: Choosing between them

| | Cassandra / ScyllaDB | DynamoDB |
|---|---|---|
| Ops | You run it (or Astra/Keyspaces/Scylla Cloud) | Fully managed, serverless |
| Replication model | Leaderless, tunable | Leader per partition (Multi-Paxos), strong or eventual reads |
| Multi-region | Native multi-DC, `LOCAL_QUORUM` | Global tables (LWW) |
| Cost at very high steady throughput | Often cheaper (hardware) | Can be expensive; reserved capacity helps |
| Strong consistency / CAS | LWT (Paxos, slower) | Conditional writes (cheap), transactions |
| Portability | Open source, any cloud | AWS only |
| Typical users | Netflix, Apple, Discord (Scylla), Uber | Amazon retail, Lyft, Snap, countless AWS shops |

## Interview questions

1. **Why are Cassandra writes faster than reads?** Writes are a commit log append + memtable insert with no read-before-write; reads merge data across the memtable and multiple SSTables and apply tombstones.
2. **What's a tombstone, and why can deleted data come back?** A delete marker. If a replica misses the delete and repair doesn't run within `gc_grace_seconds`, the tombstone is purged elsewhere and the old value is "repaired" back.
3. **Why not build a queue on Cassandra?** Each dequeue leaves a tombstone; reads scan growing tombstone piles until queries fail.
4. **How do you model "latest N messages per chat"?** Partition by (chat_id, time bucket), cluster by message timeuuid descending.
5. **How does DynamoDB handle a hot partition?** Adaptive capacity and split-for-heat, but a single key is still capped (~1,000 WCU), so write-shard the key or batch.
6. **How do you do optimistic locking in DynamoDB?** A version attribute and `ConditionExpression: version = :expected`; on `ConditionalCheckFailedException`, re-read and retry.
7. **GSI vs LSI?** GSI: any key, async (eventually consistent), separate capacity, can throttle base writes. LSI: same partition key, strong reads possible, created at table creation, 10 GB per item collection.
8. **Is DynamoDB Dynamo?** No. Dynamo (2007) is leaderless with sloppy quorums. DynamoDB uses Multi-Paxos replication groups per partition with a leader.
9. **Can you enforce a unique username with global tables?** Not safely across regions (LWW). Route claims to one region, or use the multi-region strong consistency mode.
10. **QUORUM vs LOCAL_QUORUM?** QUORUM counts replicas across all DCs (cross-region latency); LOCAL_QUORUM only in the local DC (fast, but other DCs catch up asynchronously).
