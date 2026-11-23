# Consensus: Paxos, Raft, ZAB, and Leader Election

> **Go deeper:** [ZooKeeper and etcd in practice](../09-technology-deep-dives/07-zookeeper-etcd.md)

## What consensus solves

Getting a group of nodes to **agree on a value** (or a sequence of values, i.e., a log) despite failures.

**Properties:**

- **Agreement:** no two nodes decide differently
- **Validity:** the decided value was proposed by someone
- **Integrity:** decide at most once
- **Termination:** non-failed nodes eventually decide (only under partial synchrony; see FLP)

**Things equivalent to consensus:** total order broadcast, linearizable compare-and-set, atomic commit (with caveats), leader election, distributed locks, membership agreement.

**Why it matters:** every strongly consistent system has consensus at its core: etcd (Kubernetes), ZooKeeper (old Kafka, HBase, Hadoop), Spanner (Paxos per split), CockroachDB/TiKV/YugabyteDB (Raft per range), Kafka KRaft (Raft for metadata), Consul.

## Quorum math

- **2f + 1** nodes tolerate **f** failures.
- 3 nodes → 1 failure, 5 → 2, 7 → 3.
- Majority quorums **always intersect**, so any two majorities share at least one node, which carries the latest committed state.
- **Even numbers add no tolerance:** 4 nodes tolerate 1 failure (same as 3), with higher latency.
- **More nodes = slower writes** (wait for more acks, plus more network traffic). 5 is the sweet spot for most control planes.

## Raft (Ongaro & Ousterhout, 2014): know this well

Designed for understandability. Equivalent in power to Multi-Paxos.

### Roles

- **Leader:** handles all client writes and replicates the log
- **Follower:** passive; responds to leader and candidates
- **Candidate:** trying to become leader

### Terms
Time is divided into **terms** (monotonically increasing integers). Each term has at most one leader. **Terms act as logical clocks and fencing tokens.** Any message with a stale term is rejected; a node seeing a higher term steps down to follower.

### Leader election

1. A follower hears no heartbeat within the **election timeout** (randomized, e.g., 150–300ms, to avoid split votes).
2. It becomes a candidate, increments its term, votes for itself, and sends `RequestVote` to all.
3. A node grants its vote if (a) it hasn't voted in this term and (b) **the candidate's log is at least as up-to-date** as its own (compare last log term, then last log index).
4. A majority of votes → leader. It starts sending heartbeats (empty `AppendEntries`).
5. Split vote → timeout → new election with a higher term.

**Election restriction (rule b) is the key safety property:** only a node with every committed entry can become leader.

### Log replication

1. Client sends a command to the leader.
2. The leader appends to its log (index, term, command).
3. The leader sends `AppendEntries(prevLogIndex, prevLogTerm, entries[], leaderCommit)` to followers.
4. A follower accepts only if its log matches at `prevLogIndex`/`prevLogTerm` (**log matching property**). Otherwise it rejects, the leader decrements nextIndex and retries, and conflicting entries are overwritten.
5. Once a **majority** have stored the entry, it's **committed**. The leader applies it to the state machine and replies to the client.
6. Followers learn the commit index from later messages and apply it.

**Subtlety:** a leader only commits entries from **its own term** by counting replicas. Entries from previous terms commit indirectly when a current-term entry after them commits. (This avoids the Figure 8 scenario in the Raft paper.)

### Linearizable reads in Raft
Reading from the leader isn't automatically safe, because a deposed leader might not know it was deposed. Options:

- **Log the read** through Raft (slow, but simple)
- **ReadIndex:** the leader records the commit index, confirms leadership with a heartbeat round to a majority, waits until applied ≥ that index, then serves the read
- **Leader lease:** the leader assumes leadership for a lease period after heartbeat acks (relies on bounded clock drift). Faster but timing-dependent.
- **Follower reads:** a follower asks the leader for the ReadIndex, waits to catch up, then serves (offloads the leader)

### Membership changes
Changing the cluster configuration safely: **joint consensus** (old + new majorities both needed during the transition) or **single-server changes** (add/remove one node at a time, since any two consecutive configs' majorities overlap).

### Log compaction
Snapshots of state machine state; truncate the log before the snapshot. Lagging followers receive `InstallSnapshot`.

### Raft failure scenarios to know

| Scenario | What happens |
|---|---|
| Leader crashes | Followers time out, a new election; uncommitted entries on the old leader may be lost (the client never got an ack, so it's fine) |
| Network partition, leader in minority | Old leader can't commit (no majority); majority side elects a new leader with a higher term; on heal, the old leader sees the higher term and steps down; its uncommitted entries are overwritten |
| Follower crashes | Leader keeps retrying; when it recovers it catches up |
| Flaky node disrupting elections | Rejoining node with a high term forces re-elections. Fix: **PreVote** (check you could win before incrementing the term) and CheckQuorum |

## Paxos (Lamport, 1989/1998)

### Single-decree Paxos (agree on one value)
Roles: proposers, acceptors, learners.

**Phase 1 (Prepare/Promise):**

- Proposer picks proposal number `n` and sends `Prepare(n)` to acceptors.
- Acceptor: if `n` > any prepare it has seen, it promises not to accept proposals < n and returns any value it already accepted (with its number).

**Phase 2 (Accept/Accepted):**

- If a majority promises, the proposer sends `Accept(n, v)`, where `v` = the value of the highest-numbered accepted proposal from the promises, or its own value if none.
- Acceptors accept unless they've promised a higher n.
- Once a majority accepts, the value is **chosen**.

**Key insight:** a proposer must adopt any previously accepted value, which guarantees that once chosen, a value stays chosen.

### Multi-Paxos
Run Paxos for each log slot. **Optimization:** elect a stable leader that skips Phase 1 for subsequent slots, so steady state = one round trip. That's essentially what Raft formalizes.

### Variants

- **Fast Paxos:** clients send directly to acceptors; 1 RTT when there are no conflicts, larger quorums needed
- **EPaxos (Egalitarian):** leaderless; commutative commands commit in 1 RTT from any replica. Good for geo-distribution.
- **Flexible Paxos:** Phase 1 and Phase 2 quorums only need to intersect each other, not be majorities (e.g., small Phase 2 quorums for fast commits, large Phase 1 for rare elections)

## ZAB (ZooKeeper Atomic Broadcast)

- Similar to Raft (leader-based, epochs ~ terms, zxid = (epoch, counter)).
- Phases: leader election → discovery → synchronization → broadcast.
- Primary-order guarantees: a leader's transactions are delivered in order, and a new leader's transactions come after all of the previous leader's committed ones.

## Byzantine fault tolerance (awareness)

- Tolerating malicious nodes needs **3f + 1** nodes for f faults.
- PBFT, Tendermint, HotStuff (Diem/Libra). Used in blockchains and some high-assurance systems.
- Rarely relevant in data-center system design interviews.

## Using consensus in system design

You rarely implement consensus. You **use** a consensus-backed service:

| Use case | Tool |
|---|---|
| Leader election | etcd lease, ZooKeeper ephemeral nodes, Consul sessions, K8s Lease |
| Distributed locks with fencing | etcd, ZooKeeper |
| Configuration / service discovery | etcd, Consul, ZooKeeper |
| Cluster membership / metadata | KRaft (Kafka), etcd (K8s) |
| Replicated state machine for your data | Raft libraries (etcd/raft, hashicorp/raft, Apache Ratis), or a DB built on Raft |
| Sharded strongly consistent DB | Multi-Raft: each shard/range is its own Raft group (CockroachDB, TiKV, YugabyteDB) |

**Design principle:** keep consensus **off the data path for high-throughput data** where possible. Use it for **metadata and control** (who owns which shard, who's leader) and let the data path use simpler leader-based replication with leases and fencing. Examples: Kafka (controller via KRaft, data via ISR), GFS/HDFS (master metadata), Bigtable (Chubby for the master lock).

**Multi-Raft at scale:** thousands of Raft groups per node means heartbeat overhead. Solutions: coalesced heartbeats and quiescing idle ranges (CockroachDB).

## Interview sound bites

- "Raft tolerates f failures with 2f+1 nodes; I'll run 5 nodes across 3 AZs (2-2-1), so we survive an AZ loss."
- "The term number works as a fencing token, so a deposed leader's writes are rejected."
- "Consensus gives linearizable writes, but reads also need ReadIndex or a lease, otherwise a stale leader can serve old data."
- "I'll keep etcd for metadata only. It's not built for high-throughput data (etcd's recommended DB size is a few GB)."
