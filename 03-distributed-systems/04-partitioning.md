# Partitioning (Sharding) and Consistent Hashing

**Goal:** spread data and load across nodes so that no node is a bottleneck, while keeping queries efficient.

## Partitioning strategies

### 1. Range partitioning
Keys are split into contiguous ranges: `[a–f]`, `[g–m]`, ...

- ✅ Efficient range scans (`WHERE ts BETWEEN ...`), ordered iteration.
- ❌ **Hot spots** on sequential keys. Timestamp keys send all writes to the last partition.
- Examples: Bigtable/HBase (tablets/regions), Spanner, CockroachDB, MongoDB range sharding, TiKV.
- Ranges split automatically when large or hot (dynamic splitting).

### 2. Hash partitioning
`partition = hash(key) mod N` (naive) or via consistent hashing.

- ✅ Uniform distribution.
- ❌ No efficient range queries (adjacent keys scatter).
- Examples: Cassandra, DynamoDB, Redis Cluster (16,384 hash slots), Kafka (default partitioner).

### 3. Compound key (best of both)
Cassandra/DynamoDB: **partition key** (hashed) + **sort/clustering key** (sorted within the partition).
```
PRIMARY KEY ((user_id), created_at)
→ all of a user's posts on one partition, sorted by time
```
Gives "range scan within an entity" plus uniform distribution across entities. **The most common data-modeling pattern for NoSQL at scale.**

### 4. Directory-based / lookup service
A lookup table maps key → shard. Maximum flexibility (move individual tenants) at the cost of an extra lookup and the directory being critical infrastructure. Used for multi-tenant SaaS (big tenants on dedicated shards). Vitess uses a keyspace ID and a VSchema.

### 5. Geographic partitioning
Partition by region or country for latency and data residency (GDPR).

## Why `hash(key) mod N` is bad

Changing N from 10 to 11 remaps ~**91%** of keys. That's a massive data migration and a cold cache.

## Consistent hashing

- Hash both nodes and keys onto a ring (0 to 2^32−1 or 2^64−1).
- A key belongs to the **first node clockwise** from its hash.
- Adding or removing a node moves only **~K/N keys** (the neighbouring segment).

```
        Node A (pos 10)
       /              \
  key k1 (5) → A      key k2 (30) → Node B (pos 40)
       \              /
        Node C (pos 80)   key k3 (90) → wraps → A
```

### Virtual nodes (vnodes)
Problem: with few nodes, ring segments are uneven, and when a node leaves, its whole load goes to one neighbour.

Fix: each physical node owns **many points** (e.g., 100–256 vnodes) on the ring.

- ✅ Even distribution (law of large numbers)
- ✅ When a node fails, its load spreads across **many** nodes
- ✅ Heterogeneous hardware: bigger machines get more vnodes
- ❌ More metadata; repair and streaming touch more peers

### Replication on the ring
Key is stored on the first node clockwise **plus the next N−1 distinct physical nodes** (the preference list). Skip vnodes on the same physical node or rack/AZ.

### Alternatives

- **Rendezvous (highest random weight) hashing:** for each key, compute `hash(key, node)` for every node and pick the max. Simple, minimal movement, O(N) per lookup (fine for small N). Used in some CDNs and load balancers.
- **Jump consistent hash (Google):** O(ln N), no memory, perfect balance, but nodes must be numbered sequentially (no arbitrary removal). Good for sharded storage with stable shard counts.
- **Maglev hashing (Google LB):** lookup table with good balance and minimal disruption. Used for L4 load balancing.
- **Fixed number of partitions (most practical):** create many more partitions than nodes (e.g., 1,024 partitions for 10 nodes). Moving a partition = moving a whole unit. Kafka, Elasticsearch (fixed primary shards), Riak, Couchbase (1,024 vBuckets), Redis Cluster (16,384 slots).

## Rebalancing

| Approach | How | Notes |
|---|---|---|
| Fixed partitions | Move whole partitions between nodes | Simple; choose the partition count carefully up front (ES shards can't change without reindex) |
| Dynamic splitting | Split partitions when they get too big/hot; merge when small | HBase, Bigtable, MongoDB, CockroachDB, DynamoDB |
| Proportional to nodes | Fixed partitions per node; new node splits random partitions | Cassandra vnodes |

**Operational guidance:**

- **Rebalancing is expensive and risky.** Throttle data movement; it competes with production traffic.
- Many teams keep a **human in the loop** for rebalancing decisions. Fully automatic rebalancing combined with automatic failure detection can cascade (a slow node is deemed dead, its data moves, which adds load, so more nodes look dead).

## Secondary indexes in a partitioned system

### Local (document-partitioned) index
Each partition indexes only its own data.

- ✅ Writes touch one partition.
- ❌ Reads by secondary key must **scatter-gather** across all partitions, and tail latency suffers.
- Examples: MongoDB, Cassandra secondary indexes, Elasticsearch.

### Global (term-partitioned) index
The index itself is partitioned by the indexed term.

- ✅ Reads by secondary key hit one index partition.
- ❌ Writes touch multiple partitions (data + index), usually **asynchronously**, so the index is eventually consistent.
- Examples: DynamoDB GSIs (async), Spanner/CockroachDB secondary indexes (transactional).

## Hot spots and skew (the real-world problem)

Even with perfect hashing, **one key can be hot** (celebrity, viral post, flash-sale SKU).

Mitigations:

- **Key salting:** `hot_key#0..#9`, writes spread across 10 partitions, reads gather all 10. Only for detected hot keys.
- **Read replicas / caching** for read-hot keys
- **Write batching** for write-hot keys
- **Adaptive splitting:** DynamoDB splits partitions for heat; Bigtable splits hot tablets
- **Detect skew:** per-partition metrics, top-K key tracking

## Cross-partition operations

- **Joins:** avoid by denormalizing, co-locating related data (same partition key, e.g., `tenant_id`), or using broadcast joins for small tables.
- **Transactions:** single-partition transactions are cheap; cross-partition ones need 2PC or sagas. **Design partition keys so the common transactions are single-partition.**
- **Aggregations:** scatter-gather, or maintain pre-aggregated views.

## Choosing a partition key (interview checklist)

1. **High cardinality** (many distinct values) for even distribution
2. **Matches the dominant access pattern** (most queries include it)
3. **Keeps transactional units together** (an order and its line items)
4. **Avoids monotonic values** as the hash input when range partitioning (timestamps, auto-increment)
5. **Plan for hot keys** separately
6. **Think about resharding** from day one (logical shards > physical nodes)

### Examples

| System | Partition key | Why |
|---|---|---|
| Chat messages | `conversation_id` | All messages of a chat together, ordered by message_id |
| Timeline | `user_id` | One user's feed is one partition |
| Orders | `customer_id` (or `order_id`) | Customer order history vs even spread |
| IoT metrics | `(device_id, day)` | Bounded partition size (time bucket avoids huge partitions) |
| Multi-tenant SaaS | `tenant_id` | Isolation; big tenants get dedicated shards |
| URL shortener | `short_code` | Point lookups, uniform |

**Bounded partition size:** Cassandra partitions should stay under ~100 MB. If a key grows unboundedly (a chat with millions of messages), add a time bucket: `((conversation_id, month), message_id)`.
