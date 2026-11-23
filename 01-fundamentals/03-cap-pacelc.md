# CAP, PACELC, and What They Actually Mean

## CAP theorem (Brewer 2000, proven by Gilbert & Lynch 2002)

In the presence of a **network partition (P)**, a distributed system must choose between:

- **Consistency (C):** here this means **linearizability**. Every read sees the most recent write, as if there were a single copy.
- **Availability (A):** every request to a **non-failed** node gets a (non-error) response.

### Common misunderstandings (interviewers probe these)

1. **"Pick 2 of 3" is misleading.** Partitions aren't optional; they happen. The real choice is **what you do during a partition**: refuse (CP) or serve possibly-stale data (AP).
2. **C in CAP ≠ C in ACID.** ACID's C is about invariants such as constraints. CAP's C is linearizability.
3. **A in CAP is very strict:** *every* non-failed node must respond. Most "CP" systems are still highly available in practice; they just can't serve from the minority side of a partition.
4. **It's per operation, not per system.** One system can offer linearizable writes on some paths and stale reads on others (e.g., DynamoDB consistent vs eventual reads).
5. **Most systems are neither strictly CP nor AP.** A Postgres primary with async replicas, reading from replicas, is neither linearizable nor fully available during a partition.

### Examples

| System | Partition behaviour | Category |
|---|---|---|
| ZooKeeper, etcd, Consul | Minority side refuses writes (and linearizable reads) | CP |
| Spanner | CP with very high availability through redundancy and a private network | CP ("effectively CA") |
| Cassandra, DynamoDB (default), Riak | Serve reads/writes on any reachable replica | AP (tunable) |
| MongoDB (majority write concern) | Minority primary steps down | CP-ish |
| Redis Cluster | Can lose acknowledged writes on failover | Neither strictly |

## PACELC (Abadi 2010): the more useful one

> **If Partition**: choose **A**vailability or **C**onsistency.
> **Else** (normal operation): choose **L**atency or **C**onsistency.

The "else" branch matters more day to day. Even without partitions, **strong consistency costs latency** because you need to coordinate with replicas (often cross-AZ or cross-region) before acknowledging.

| System | P: A or C | E: L or C |
|---|---|---|
| Dynamo, Cassandra | PA | EL |
| Spanner, CockroachDB | PC | EC |
| MongoDB | PC (with majority) | EC |
| PNUTS (Yahoo) | PC | EL |
| MySQL with async replicas | PA-ish | EL |

## How to use this in an interview

Don't say "I'll pick AP." Say:

> "For the shopping cart, availability matters more than consistency: we'd rather let users add items during a partition and merge carts later. That's an AP choice with merge-on-conflict, like Dynamo did. For checkout and inventory decrement, I need linearizable operations on the stock count, so that path goes to a CP store and returns an error during a partition rather than overselling."

## Consistency vs latency in numbers

- Single-region synchronous replication across 3 AZs: +1–2 ms per write.
- Cross-region synchronous replication (US-East ↔ US-West): +60–70 ms per write.
- Global Spanner commit with TrueTime commit-wait: ~5–10 ms wait plus cross-region Paxos.

That's the cost of "EC." Many systems pick EL for most operations and EC only where it matters.

## Related: the FLP impossibility result

**Fischer, Lynch, Paterson (1985):** in an asynchronous system where even one process may crash, no deterministic consensus algorithm is guaranteed to terminate.

**Practical meaning:** consensus protocols (Paxos, Raft) are always **safe**, but they rely on timeouts (partial synchrony) to make **progress**. Under bad network conditions they can stall (no leader elected) but never violate safety.
