# Replication

**Why replicate:** availability (survive failures), durability (don't lose data), read scaling, and lower latency (data close to users).

**The core difficulty:** keeping replicas in sync under concurrent writes and failures.

## Three architectures

### 1. Single-leader (primary-replica)

```
Writes → Leader → replication log → Followers
Reads  → Leader (fresh) or Followers (possibly stale)
```
- Examples: PostgreSQL, MySQL, MongoDB replica sets, Redis, Kafka (per partition), most Raft systems.
- ✅ Simple, no write conflicts, easy to reason about.
- ❌ The leader is a write bottleneck and failover is tricky.

#### Synchronous vs asynchronous replication
| | Sync | Async | Semi-sync |
|---|---|---|---|
| Write latency | Waits for replica ack | Immediate | Waits for ≥1 replica |
| Durability on leader crash | No loss | **Can lose recent writes** | No loss if the ack'd replica survives |
| Availability | Blocks if a replica is down | Unaffected | Degrades to async on timeout (MySQL) |

In practice: **quorum or semi-sync** (e.g., Raft majority, Postgres `synchronous_standby_names = ANY 1 (...)`).

#### Replication log types
- **Statement-based:** replay SQL. Breaks with non-determinism (`NOW()`, `RAND()`).
- **WAL shipping (physical):** byte-level. Tied to storage format, so you can't replicate across versions.
- **Logical (row-based):** row changes. Version-independent, enables **CDC** (Debezium, MySQL binlog row format).
- **Trigger-based:** flexible, slow.

#### Failover (where things go wrong)
1. Detect leader failure (timeout; risk of false positives)
2. Elect a new leader (the most up-to-date replica; consensus helps)
3. Reconfigure clients to the new leader
4. **Fence the old leader** so it stops accepting writes when it returns

Failure modes:
- **Lost writes:** async replication means the new leader lacks the old leader's last writes. If those writes generated IDs used elsewhere (e.g., Redis cache keys or a foreign system), you get inconsistency. (GitHub 2012 MySQL incident: auto-increment IDs reused after failover exposed private data in Redis.)
- **Split brain:** both think they're leader. Fix with fencing and STONITH.
- **Flapping:** timeout too short leads to repeated failovers.

### 2. Multi-leader (active-active)

```
Region A leader ⇄ Region B leader ⇄ Region C leader
```
- Each region accepts writes locally and replicates asynchronously to the others.
- Examples: multi-region apps, CouchDB, offline-first mobile apps (each device is a "leader"), collaborative editing, MySQL Group Replication multi-primary, DynamoDB Global Tables.
- ✅ Local write latency in every region; survives region failure.
- ❌ **Write conflicts.** The same key is modified in two regions concurrently.

#### Conflict resolution strategies
| Strategy | How | Trade-off |
|---|---|---|
| **Avoid conflicts** | Route all writes for a key to its "home" region | Best option when possible |
| **Last-writer-wins (LWW)** | Highest timestamp wins | **Silent data loss**; clock skew |
| **Merge values** | Union sets, concatenate | Domain-specific |
| **Return siblings to app** | Keep all versions, app or user resolves | Complex app logic (Dynamo shopping cart) |
| **CRDTs** | Data types that merge automatically | Limited types; metadata overhead |
| **Custom resolver** | On-write or on-read handler | Flexible, bug-prone |

Topologies: all-to-all (most robust, but causality issues since messages can overtake), circular, star. All-to-all needs version vectors to order causally dependent writes.

### 3. Leaderless (Dynamo-style)

```
Client → writes to N replicas in parallel → success if W acknowledge
Client → reads from N replicas → success if R respond → pick latest by version
```
- Examples: Amazon Dynamo (the 2007 paper), Cassandra, Riak, ScyllaDB, Voldemort.
- ✅ No failover needed; highly available for writes.
- ❌ Weak consistency by default; conflict handling needed.

#### Quorums
- N = replicas, W = write acks required, R = read responses required.
- **W + R > N** means read and write sets overlap, so a read sees at least one up-to-date replica.
- Common: N=3, W=2, R=2. Write-heavy: W=1, R=3. Read-heavy: W=3, R=1.

**Important: W + R > N does NOT give linearizability.** Edge cases:
- A write that succeeded on fewer than W nodes (reported as failed) isn't rolled back; later reads may or may not see it.
- Concurrent write and read: the read may see the new value on one replica and old on others.
- Sloppy quorums break the overlap guarantee.
- LWW with clock skew drops writes.
- To get linearizable reads with quorums you need **read repair synchronously before returning** (ABD algorithm), and linearizable writes need more (Cassandra uses Paxos for lightweight transactions, `IF NOT EXISTS`).

#### Mechanisms to converge replicas
- **Read repair:** on read, detect stale replicas and write the latest value back.
- **Hinted handoff:** if a replica is down, another node stores the write with a "hint" and forwards it when the replica returns.
- **Sloppy quorum:** accept writes on any N healthy nodes (not necessarily the "home" nodes). Better availability, weaker consistency.
- **Anti-entropy with Merkle trees:** background comparison of replicas; Merkle trees let you find differing key ranges by comparing hashes top-down, so only differing ranges are transferred.

## Replication lag and client-visible anomalies

With async followers, lag can be ms or minutes under load.

| Guarantee | Problem it solves | Implementation |
|---|---|---|
| **Read-your-writes** | User doesn't see their own update | Read own data from leader; track last write timestamp/LSN; client-side wait |
| **Monotonic reads** | Data appears then disappears on refresh | Pin user to one replica (hash user_id) |
| **Consistent prefix** | Answer seen before question | Write causally related data to the same partition; causal tracking |

## Chain replication (alternative)

```
Write → Head → Middle → Tail → ack
Read  → Tail
```
- Strong consistency (reads from the tail see only fully replicated writes), high throughput.
- Latency grows with chain length; failures require chain reconfiguration (by an external master like ZooKeeper).
- Used in: Azure Storage (variant), CRAQ (reads from any node with version checks), some object stores.

## Replication in Raft/Paxos systems

- Leader appends to log → replicates to followers → **committed once a majority acks** → applied to the state machine.
- Survives `f` failures with `2f+1` nodes. 3 nodes tolerate 1 failure; 5 nodes tolerate 2.
- Linearizable writes; reads need a leader lease or ReadIndex to be linearizable (see [06-consensus.md](06-consensus.md)).

## Choosing a replication strategy

| Need | Choice |
|---|---|
| Simple strong consistency, single region | Single-leader with sync/quorum replica (Postgres + Patroni, Raft-based DB) |
| Read scaling, staleness OK | Single-leader + async read replicas |
| Multi-region with local writes, conflicts rare or mergeable | Multi-leader (avoid conflicts via home region) or CRDTs |
| Always-writable, high availability, tunable consistency | Leaderless (Cassandra/DynamoDB) |
| Global strong consistency | Consensus-based (Spanner, CockroachDB): pay cross-region latency on writes |
