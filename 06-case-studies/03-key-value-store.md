# Case Study 03: Distributed Key-Value Store (Dynamo / Cassandra style)

> The most comprehensive distributed-systems question. It exercises partitioning, replication, consistency, versioning, failure detection, and repair. Based on the Amazon Dynamo paper (2007).

## 1. Requirements

**Functional:** `put(key, value)`, `get(key)`, `delete(key)`. Values up to ~1 MB.

**Non-functional**

- Massive scale: petabytes, millions of ops/s
- **Always writable** (highly available) even during failures and partitions (Dynamo's shopping cart requirement)
- Low latency: p99.9 < 10ms within a region
- **Tunable consistency**
- Incremental scalability (add nodes without downtime)
- No single point of failure; symmetric nodes

## 2. Core design decisions (Dynamo's toolkit)

| Problem | Technique | Advantage |
|---|---|---|
| Partitioning | Consistent hashing + virtual nodes | Incremental scalability, even load |
| High write availability | Sloppy quorum + hinted handoff | Writes succeed even when home replicas are down |
| Conflict handling | Vector clocks + read-time reconciliation | Detect concurrent writes; app or LWW merges |
| Temporary failures | Hinted handoff | Durability while nodes are briefly down |
| Permanent failures | Anti-entropy with Merkle trees | Efficient background replica sync |
| Membership & failure detection | Gossip | Decentralized, no SPOF |

## 3. Architecture

```
Client → (any node = coordinator, or partition-aware client)
           │
           ├── hash(key) → ring position → preference list of N nodes
           ├── write to N replicas in parallel, wait for W acks
           └── read from N replicas, wait for R responses, reconcile
```

Every node runs: request coordinator, storage engine (LSM: memtable + commit log + SSTables), gossip/membership, failure detector, anti-entropy.

## 4. Deep dive: partitioning

- Consistent hash ring (e.g., MD5/Murmur3 → 128/64-bit space).
- **Virtual nodes:** each physical node owns ~256 tokens, giving even distribution, faster rebuilds (many peers stream in parallel), and weighting by capacity.
- **Preference list:** the first N **distinct physical nodes** clockwise, spread across racks/AZs (rack-aware placement).
- Adding a node: it takes over token ranges from neighbours and streams data; the rest of the cluster is unaffected.

## 5. Deep dive: replication and quorums

- N = 3 typical. **W + R > N** for overlapping read/write sets (e.g., W=2, R=2).
- Tune per use case:
    - W=1, R=1: fastest, weakest
    - W=2, R=2: balanced
    - W=3, R=1: fast reads, writes fail if any replica is down
- **Coordinator:** sends to all N, returns when W/R respond (the rest complete in the background).
- Multi-DC: `LOCAL_QUORUM` (quorum within the local DC) for latency; async to other DCs.

**Important nuance (say it):** W + R > N is **not linearizable** (concurrent ops, failed partial writes, sloppy quorums, LWW clock issues). For compare-and-set, add a Paxos-based path (Cassandra lightweight transactions: `INSERT ... IF NOT EXISTS`, 4 round trips).

## 6. Deep dive: versioning and conflicts

Concurrent writes during a partition create divergent versions.

**Vector clocks** (per key): a list of `(node, counter)`.
```
Write by Sx:    D1 [(Sx,1)]
Write by Sx:    D2 [(Sx,2)]
Partition: concurrent writes
  via Sy:       D3 [(Sx,2),(Sy,1)]
  via Sz:       D4 [(Sx,2),(Sz,1)]
Read sees D3 and D4: neither descends from the other → return both siblings
Client merges → writes D5 [(Sx,3),(Sy,1),(Sz,1)] via Sx
```

- Clock size: truncate the oldest entries beyond ~10 (lossy, rarely a problem in practice).
- **Alternative: LWW by timestamp** (Cassandra). Simple, but loses concurrent writes. Use for data where that's acceptable.
- **CRDTs** for automatic merging (Riak data types).

## 7. Deep dive: handling failures

### Temporary failures: sloppy quorum + hinted handoff

- Node A (in the preference list) is down → write goes to node D (next on the ring) with a **hint** "this belongs to A."
- D stores it separately and delivers it when A recovers.
- Writes stay available, but **reads may miss data** temporarily (sloppy quorum breaks the overlap guarantee).

### Permanent failures: anti-entropy with Merkle trees

- Each node keeps a Merkle tree per token range: leaves = hashes of key ranges, parents = hashes of children.
- Two replicas compare root hashes; if they differ, recurse into children. **Only differing ranges are exchanged**, which is O(log n) comparisons.
- Runs in the background (Cassandra `nodetool repair`). **You must run repair regularly**, or deleted data can resurrect (tombstones expire after `gc_grace_seconds`).

### Read repair
On read, if replicas disagree, the coordinator writes the latest version to stale replicas (synchronously or in the background).

### Failure detection
Gossip-based membership (every second, exchange with a random peer) + Phi accrual failure detector. See [03-distributed-systems/09-membership-gossip.md](../03-distributed-systems/09-membership-gossip.md).

## 8. Deep dive: storage engine (per node)

LSM tree:
```
write → commit log (fsync policy) + memtable → flush → SSTable
read  → memtable → row cache → Bloom filters → SSTables (newest first) → merge
```

- Compaction strategies by workload (size-tiered, leveled, time-window).
- Deletes are tombstones; purged after the grace period and compaction.
- Per-SSTable Bloom filters avoid disk reads for absent keys.

## 9. Write and read paths (put it together)

**Write (W=2, N=3):**

1. Client → coordinator (token-aware client picks a replica directly)
2. Coordinator computes the preference list [A, B, C]; increments the vector clock
3. Sends to A, B, C in parallel
4. Each appends to its commit log + memtable and acks
5. On 2 acks → success to client. (If C is down → hint stored on D.)

**Read (R=2):**

1. Coordinator asks A, B, C (or 2 of them + a digest from the 3rd)
2. Waits for 2 responses
3. Compares versions: one dominates → return it (read repair stale nodes); concurrent → return siblings or LWW

## 10. Consistency options to offer the interviewer

| Need | Configuration |
|---|---|
| Max availability (shopping cart) | W=1, sloppy quorum, siblings merged by app |
| Read-your-writes-ish | W=QUORUM, R=QUORUM |
| Compare-and-set (unique username) | Paxos LWT path |
| Cross-DC latency | LOCAL_QUORUM |

## 11. Follow-ups

- **Hot keys:** a single key's replicas are overloaded. Add client-side caching, a request coalescing layer, or split the key by application design.
- **Large partitions:** bound partition size (bucketing).
- **TTL support:** per-cell expiry stored in SSTables; dropped at compaction.
- **Range scans:** hashing destroys order. Use order-preserving partitioning (Bigtable-style ranges) if you need scans, at the cost of hot-spot handling via splits.
- **Strongly consistent KV instead?** Then: Multi-Raft (TiKV, etcd at small scale, CockroachDB's KV layer). Range-partitioned, each range a Raft group, leaseholder serving reads. Different design point (CP vs AP). **Be ready to contrast both.**
- **Backups:** SSTable snapshots (immutable files make this easy) to S3.
