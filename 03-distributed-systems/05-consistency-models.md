# Consistency Models

Consistency models are **contracts** between a data store and its clients about what values reads can return.

## The hierarchy (strongest → weakest)

```
Strict serializability (= linearizable + serializable)
        ↑
 Linearizability          Serializability
        ↑                        ↑
 Sequential consistency    Snapshot isolation
        ↑
 Causal consistency
        ↑
 PRAM / FIFO, read-your-writes, monotonic reads, monotonic writes, writes-follow-reads
        ↑
 Eventual consistency
```

Two different axes:

- **Linearizability:** single-object, real-time recency guarantee (a distributed-systems concept).
- **Serializability:** multi-object transaction isolation (a database concept). Transactions appear to run in *some* serial order, which need not match real time.
- **Strict serializability:** both. Transactions appear in a serial order consistent with real time. (Spanner calls it "external consistency.")

## Linearizability

**Definition:** every operation appears to take effect atomically at some point between its invocation and its response, and every operation sees the latest completed write. The system behaves **as if there's a single copy**.

Example of a **violation:**
```
Alice: write(x=1) ——completes——
                                 Bob: read(x) → 0   ← stale; violates linearizability
```

**Where you need it:**

- **Leader election / locks:** everyone must agree who holds the lock
- **Uniqueness constraints:** usernames, seat booking
- **Cross-channel timing dependencies:** upload an image to storage, then send a message to a resizer via a queue. If storage isn't linearizable, the resizer might read the old image.
- Bank balances, inventory

**Cost:** requires coordination (consensus or a single leader). Latency is at least one round trip to a quorum, and the system is unavailable on the minority side of a partition (CAP).

**Implementations:** single-leader with sync replication and reads from the leader (with care), Raft/Paxos (etcd, ZooKeeper writes, Spanner), Cassandra LWT (Paxos per partition).

**ZooKeeper note:** writes are linearizable; reads are **not** by default (served by any server, possibly stale). Call `sync()` before a read for linearizable reads.

## Sequential consistency

All operations appear in **some total order** consistent with each client's program order, but not necessarily real time. Weaker than linearizability: a client might read a stale value as long as everyone agrees on the order.

## Causal consistency

**Operations that are causally related are seen by everyone in the same order. Concurrent operations may be seen in different orders.**

Example: Alice posts "I lost my job" → Bob comments "Sorry to hear that." Everyone must see the post before the comment. But two unrelated posts can appear in different orders for different users.

- **The strongest model that remains available during partitions** (proven: causal+ is the strongest achievable under AP).
- Implementation: track dependencies (vector clocks, explicit dependency lists). COPS, Eiger, MongoDB causal sessions.
- Practical alternative: put causally related data in the same partition.

## Session guarantees (client-centric)

Often all you need, and cheap to provide:

| Guarantee | Meaning | Example violation |
|---|---|---|
| **Read-your-writes** | You see your own writes | Edit profile → refresh → old profile |
| **Monotonic reads** | You never see time go backward | See 5 comments → refresh → see 3 |
| **Monotonic writes** | Your writes apply in order | "Set password" then "update email" applied reversed |
| **Writes-follow-reads** | Your write is ordered after what you read | Reply appears before the message it replies to |

Implementation: sticky routing, session tokens with a version/LSN, reading from the leader.

## Eventual consistency

**If no new writes occur, all replicas eventually converge to the same value.**

- No bound on "eventually" and no guarantee on what you read meanwhile.
- **Strong eventual consistency (SEC):** replicas that received the same set of updates are in the same state, with no conflicts left to resolve (CRDTs give this).

**Measuring "eventually":** in practice, replication lag is usually ms to seconds. Monitor it (p99 replication lag) and design for the worst case (minutes during incidents).

## Tunable consistency in practice

| System | Options |
|---|---|
| **Cassandra** | Per-query: `ONE`, `QUORUM`, `LOCAL_QUORUM`, `EACH_QUORUM`, `ALL`, `SERIAL` (Paxos) |
| **DynamoDB** | Eventually consistent reads (default, half cost) or strongly consistent reads (from leader; same region only); transactions |
| **MongoDB** | Write concern (`w:1`, `w:majority`), read concern (`local`, `majority`, `linearizable`), causal sessions |
| **CosmosDB** | Five levels: Strong, Bounded staleness, Session, Consistent prefix, Eventual |
| **Postgres replicas** | Async (eventual), sync (`remote_apply` for read-your-writes on replicas) |

## Choosing per operation (the senior approach)

| Operation | Model | Why |
|---|---|---|
| Like count, view count | Eventual | Staleness harmless |
| Social feed | Eventual + read-your-writes for own posts | User expects to see own post |
| Comments thread | Causal (consistent prefix) | Replies after parents |
| Shopping cart | Eventual + merge (AP) | Availability > consistency |
| Inventory decrement, seat booking | Linearizable | Prevent overselling |
| Payments, ledger | Serializable / strict serializable | Money invariants |
| Username uniqueness | Linearizable | Exactly one owner |
| Configuration / feature flags | Eventual with bounded staleness | Seconds of lag OK |
| Leader election, locks | Linearizable | Safety |

## Bounded staleness

"Reads are at most T seconds or K versions behind." A practical middle ground: CosmosDB, Spanner stale reads (`read at timestamp now − 10s`, which can be served by any replica without coordination and is much faster).

**Spanner trick:** for read-only queries that tolerate ~10s staleness, use stale reads to avoid the leader and serve from the nearest replica.

## Interview tips

- Never say "strongly consistent" without saying **what for**. Name the model.
- Distinguish **linearizable** (recency) from **serializable** (transaction isolation).
- Know that **quorums ≠ linearizable** and **ZooKeeper reads ≠ linearizable** by default.
- Know that **causal** is the strongest available-under-partition model.
- Offer **session guarantees** as the cheap fix for most user-facing "I don't see my update" problems.
