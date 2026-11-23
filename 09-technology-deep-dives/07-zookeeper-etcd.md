# ZooKeeper and etcd: Coordination Services Deep Dive

> Whenever a design needs leader election, distributed locks with fencing, service discovery, configuration, or shard-ownership metadata, the answer is a **consensus-backed coordination service**. Interviewers expect you to know what these services guarantee, how the recipes work, and why you **don't** put bulk data in them. Background: [consensus](../03-distributed-systems/06-consensus.md), [distributed locks](../02-concurrency/05-distributed-locks.md).

## 1. What a coordination service gives you

| Primitive | Why it matters |
|---|---|
| **Linearizable writes** (consensus) | Everyone agrees on the order of changes |
| **Compare-and-set / conditional transactions** | Build locks and elections safely |
| **Sessions / leases with TTL** | State that disappears when its owner dies (liveness) |
| **Watches** | React to changes without polling |
| **Monotonic versions / revisions** | **Fencing tokens** for free |
| Small, highly available key-value store | Config, membership, shard maps |

**Not for:** large data (keep it to megabytes, at most a few GB), high write throughput (thousands of writes/s, not millions), or anything on the per-request data path.

## 2. ZooKeeper

### Data model

- A hierarchical namespace of **znodes** (`/app/config/db`, `/locks/job-42/lock-0000000017`), each holding small data (≤ 1 MB, keep it to KBs) with a version number.
- **Persistent** znodes (stay until deleted), **ephemeral** znodes (deleted when the creating session ends), **sequential** znodes (ZooKeeper appends a monotonically increasing counter), **container** and **TTL** znodes.

### Sessions

- A client keeps a session alive with heartbeats. If the ensemble doesn't hear from it within the **session timeout**, the session expires and its **ephemeral nodes are deleted**.
- Subtlety: the **client may not know its session expired** (it's partitioned or paused). It must treat a disconnect as "I may have lost my locks" and stop acting until it reconnects and verifies. This is why ephemeral-node locks still need fencing.

### Watches

- One-time triggers (classic): set on a read (`getData`, `exists`, `getChildren`); fire once on the next change; the client must re-read and re-register. Changes between firing and re-registration are seen through the re-read, not as separate events.
- **Persistent (recursive) watches** since 3.6 remove the one-shot limitation.

### ZAB and consistency

- A leader orders all writes (**zxid** = epoch + counter) and commits once a quorum acknowledges. **Writes are linearizable.**
- **Reads are served locally by whichever server the client is connected to**, so they can be **stale** (sequentially consistent per client: a client never sees time go backward, but may lag other clients). Call **`sync()`** before a read to get an up-to-date view.
- Ensemble sizes: 3 or 5 voting servers; **observers** (non-voting) scale reads without slowing writes.

### Classic recipes
**Lock (fair, no herd effect):**

1. Create ephemeral sequential `/locks/R/lock-` → get `lock-0000000042`.
2. List children. If yours has the lowest number, you hold the lock.
3. Otherwise watch **only the node immediately before yours** (not the lowest), and wait. When it's deleted, go to step 2.
4. Release = delete your node (or the session dies).
5. **Fencing token:** your sequence number (or the znode's czxid). Pass it to the resource.

**Leader election:** the same recipe; the lowest sequential node is the leader. Followers watch their predecessor.

**Group membership / service registry:** each member creates an ephemeral node under `/services/payments/`; clients watch the children list.

**Configuration:** a znode with versioned data; clients watch it.

**Barrier / double barrier:** wait until N participants have created nodes.

### Where ZooKeeper is used
Historically Kafka (until KRaft), HBase, Hadoop HDFS HA, Solr, Pulsar/BookKeeper metadata, ClickHouse replication (ClickHouse Keeper is a Raft-based ZooKeeper-compatible replacement).

## 3. etcd

### Data model and storage

- A **flat key space** (use prefixes like `/registry/pods/default/web-1` for hierarchy) of byte keys and values.
- **MVCC with a global revision:** every write increments a cluster-wide **revision**. Each key tracks `create_revision`, `mod_revision`, and `version`. Old revisions are kept until **compaction**.
- Storage: bbolt (B+tree) with an in-memory index. Default quota 2 GB, **recommended max ~8 GB**. After compaction, `defrag` reclaims space.
- **Raft** for replication; 3 or 5 members; writes go through the leader.

### Leases

- A **lease** has a TTL; keys can be attached to it. When the lease expires (no `KeepAlive`), all attached keys are deleted atomically.
- One lease can cover many keys (e.g., all keys owned by one service instance).

### Watches

- Watch a key or prefix **from a specific revision**. Because history is retained (until compaction), a client that disconnects can **resume exactly where it left off** without missing events. That's a big improvement over ZooKeeper's one-shot watches, and it's how Kubernetes controllers and informers work (list at revision R, then watch from R+1).

### Transactions (mini compare-and-set language)
```
Txn().
  If(Compare(CreateRevision("/leader"), "=", 0)).        // key doesn't exist
  Then(Put("/leader", "node-7", WithLease(leaseID))).
  Else(Get("/leader")).
  Commit()
```
Atomic if/then/else over multiple keys. This is the building block for elections and locks.

### Consistency of reads

- **Linearizable reads (default):** the server confirms it's up to date with the leader (ReadIndex) before answering. Correct, slightly slower.
- **Serializable reads** (`WithSerializable()`): served from the local member's state; may be stale; faster, and available even without quorum.

### Recipes (Go client `concurrency` package)

- **Mutex:** each contender puts a key under `/lock/name/` with its lease; the key with the **lowest create_revision** holds the lock; others watch the key just before theirs (by revision). **Fencing token = the holder's key revision.**
- **Election:** `Campaign()` / `Resign()` / `Observe()` on the same mechanism.
- **Leader-with-lease pattern:** the leader must keep its lease alive; if `KeepAlive` fails it must **step down immediately**, and every write it makes to other systems should carry the revision as a fencing token.

### Where etcd is used
**Kubernetes** (the entire cluster state), CoreDNS, Vitess topology, M3, Patroni (as one option), many service meshes' control planes.

## 4. Consul (brief)

- Raft-based KV + **service discovery with health checks** + DNS interface + **gossip (Serf/SWIM)** for node membership and failure detection.
- Sessions with lock-delay; blocking queries (long-poll watches with an index).
- Roblox's 73-hour 2021 outage involved Consul overload; a reminder that everything depending on one coordination cluster is a single point of failure.

## 5. Comparison

| | ZooKeeper | etcd | Consul |
|---|---|---|---|
| Consensus | ZAB | Raft | Raft (+ gossip for membership) |
| Data model | Hierarchical znodes | Flat keys + MVCC revisions | KV + service catalog |
| Liveness | Sessions + ephemeral nodes | Leases | Sessions + health checks |
| Watches | One-shot (persistent since 3.6) | Streamed, resumable from a revision | Blocking queries |
| Default reads | Local (possibly stale), `sync()` for fresh | Linearizable | Default mode (leader, without a quorum check) |
| Fencing token | Sequential number / zxid | Revision | Session/lock index |
| Typical use | Hadoop/Kafka-era systems | Kubernetes, cloud native | Service discovery + config |

## 6. Operating them (what goes wrong)

- **Disk latency kills them:** every write is fsync'd to the Raft/ZAB log. Slow disks cause leader elections and timeouts. Use dedicated SSDs.
- **Too much data or too many watchers:** large values, millions of keys, or thousands of watchers on hot prefixes (etcd in big Kubernetes clusters). Keep data small, paginate lists.
- **Odd-sized ensembles across failure domains:** 3 members in 3 AZs survive one AZ; 5 members (2-2-1) also survive one AZ while tolerating an extra node failure.
- **Cross-region ensembles:** every write pays a cross-region round trip. Usually one coordination cluster per region, with region-scoped responsibilities.
- **Session/lease storms:** after a coordination outage, every client reconnects and re-registers at once. Jitter and backoff.
- **Compaction and defrag (etcd):** forget them and you hit the space quota → the cluster goes read-only (alarm).
- **Back up regularly** (etcd snapshots); test restores.

## 7. Using them correctly in designs

1. **Metadata, not data:** shard → owner maps, leader identity, config, membership. Kafka (KRaft), Bigtable (Chubby), and HDFS all keep consensus off the data path.
2. **Leader election + fencing:** "The scheduler leader holds an etcd lease. Every job dispatch includes the lease's revision; workers and the job store reject operations with a revision lower than the highest they've seen."
3. **Watches for config and discovery, with periodic full reconciliation** (in case a watch is missed).
4. **Expect the coordination service to be briefly unavailable:** cache the last known state and keep the data path running (**static stability**). Don't make every request depend on a ZooKeeper read.

## 8. Interview questions

1. **Why do you need ZooKeeper/etcd for leader election instead of just picking the lowest IP?** Agreement under partitions: only a quorum-backed decision guarantees a single leader per term, and it gives you a fencing token.
2. **Are ZooKeeper reads linearizable?** No, by default they're served locally and may be stale; `sync()` first for an up-to-date read. Writes are linearizable.
3. **Why watch the predecessor node rather than the lock node?** To avoid a herd effect: when the lock is released, only the next waiter wakes up.
4. **What happens if a lock holder's session expires while it's paused in GC?** Its ephemeral node is deleted, another client gets the lock, and the old holder may act on stale belief. Fencing tokens at the resource stop its writes.
5. **How do etcd watches avoid missing events?** Watches resume from a revision; history is kept until compaction (if you fall behind compaction, re-list and watch again).
6. **Why shouldn't you store large data in etcd?** Every write goes through Raft with fsync, the whole dataset is held per member, and the quota is a few GB. Large data slows the cluster and Kubernetes along with it.
7. **3 vs 5 members?** 3 tolerates 1 failure, 5 tolerates 2 (with slightly higher write latency). Don't use even numbers. Spread across AZs.
8. **Linearizable vs serializable reads in etcd?** Linearizable confirms freshness through the leader (ReadIndex); serializable reads local state, which is faster but possibly stale and available without quorum.
