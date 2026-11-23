# Time, Clocks, and Ordering

> "There is no now in a distributed system."

## Physical clocks

- **Time-of-day clock** (`System.currentTimeMillis`, `CLOCK_REALTIME`): wall time, synced by NTP. **Can jump backward** (NTP correction, leap seconds, manual change).
- **Monotonic clock** (`System.nanoTime`, `CLOCK_MONOTONIC`): only moves forward. Meaningful only for **durations on the same machine**.

**Rule:** use monotonic clocks for timeouts and durations, never wall clocks.

### Clock skew
- NTP over the internet: tens to hundreds of ms of skew. Within a DC: ~1ms, but **no guarantee**.
- Clock drift: quartz drifts ~10–200 ppm (6–17 seconds/day at worst without sync).
- VMs may pause, and leap seconds have caused major outages (2012 Linux kernel livelock).
- **Leap smearing** (Google, AWS): spread the leap second over hours.

### Why "last write wins" with wall clocks is dangerous
```
Node A (clock ahead by 100ms) writes x=1 at "10:00:00.100"
Node B (correct clock)        writes x=2 at "10:00:00.050"  (actually later in real time)
LWW keeps x=1. B's later write is silently lost.
```
Cassandra uses client or server timestamps for LWW, and this is a known source of data loss.

## Logical clocks

### Lamport timestamps (1978)
Each node keeps a counter `C`.
- On a local event: `C = C + 1`
- On send: attach `C`
- On receive with timestamp `T`: `C = max(C, T) + 1`

**Property:** if A → B (A happened-before B), then `L(A) < L(B)`.
**But the converse doesn't hold:** `L(A) < L(B)` doesn't mean A → B. You can't detect concurrency.

A total order: break ties with node ID: `(counter, node_id)`. Useful for total-order broadcast and LWW without clock skew.

### Vector clocks
Each node keeps a vector `V[n]` of counters, one per node.
- Local event: `V[self] += 1`
- Send: attach `V`
- Receive `W`: `V[i] = max(V[i], W[i])` for all i; then `V[self] += 1`

**Compare:**
- `V ≤ W` (all entries ≤): V happened-before W
- Neither ≤ the other: **concurrent**, so this is a conflict

```
A: [2,0,0]   B: [1,1,0]   → concurrent (A has more from node 0, B more from node 1)
A: [1,0,0]   B: [2,1,0]   → A happened-before B
```

**Used by:** Dynamo (version vectors per key to detect conflicting writes and return siblings), Riak.
**Cons:** size grows with the number of nodes/clients. Mitigations: version vectors per replica (not per client), pruning (lossy), dotted version vectors.

### Version vectors vs vector clocks
- **Vector clocks** track causality between events across processes.
- **Version vectors** track causality between versions of a data item across replicas. Practically similar, conceptually different.

### Hybrid Logical Clocks (HLC)
- Combine physical time and a logical counter: `(physical_ms, logical)`.
- Stays close to wall time (useful for humans and TTLs) while preserving the happened-before property like Lamport.
- **Used by CockroachDB, YugabyteDB, MongoDB** (cluster time).
- CockroachDB still needs a max-clock-offset bound (default 500ms) and has **uncertainty intervals**: if a read finds a value with timestamp within its uncertainty window, it restarts at a higher timestamp.

## TrueTime (Google Spanner)

- GPS receivers plus atomic clocks in every data center.
- API: `TT.now()` returns an **interval** `[earliest, latest]`, with uncertainty ε typically 1–7ms.
- **Commit wait:** after choosing commit timestamp `s = TT.now().latest`, Spanner **waits until `TT.now().earliest > s`** before making the commit visible. This guarantees that any transaction starting after this commit gets a higher timestamp, which gives **external consistency** (linearizability for transactions) globally.
- **Trade-off:** you pay ε of latency per write. Better clocks mean faster commits.
- **AWS Time Sync / ClockBound** offers similar bounded-error clocks (used by Aurora DSQL, DynamoDB).

## Ordering guarantees in practice

| Guarantee | Meaning | How achieved |
|---|---|---|
| **FIFO per sender** | Messages from one sender arrive in send order | TCP, sequence numbers per sender |
| **Causal order** | If m1 → m2 causally, everyone delivers m1 before m2 | Vector clocks, dependency tracking |
| **Total order** | Everyone sees all messages in the same order | Single leader / sequencer, consensus (Raft log), Kafka partition |
| **Total order per key** | Same order for each key, no global order | Partitioned log (Kafka partition by key) |

**Total order broadcast ≡ consensus.** Building a replicated log where everyone agrees on order is equivalent to solving consensus. That's why Raft/Paxos logs are the foundation.

## Practical ordering patterns

1. **Single sequencer:** one node assigns sequence numbers. Simple, a bottleneck and SPOF (mitigate with consensus-backed leader). Used in exchanges and Kafka partition leaders.
2. **Per-entity versioning:** each entity has a version incremented on every write. Consumers ignore older versions.
3. **Partitioned logs:** order per partition only, so choose the partition key as the unit that needs ordering (user_id, order_id, chat_id).
4. **Snowflake-style IDs:** roughly time-ordered (k-sorted), but not strictly ordered across generators. Fine for feeds, not for correctness.
5. **Causal consistency with explicit dependencies:** comment replies carry `parent_id`; show a reply only once the parent is visible.

## Interview gotchas

- "Sort events by timestamp from different servers": **wrong** if correctness matters. Clocks skew.
- "Use timestamps for LWW": acceptable for low-value data (presence status, last-seen); dangerous for anything users care about.
- "Generate globally ordered IDs": you need a sequencer (bottleneck) or accept k-sorted IDs.
- "Detect concurrent writes": vector clocks / version vectors, not timestamps.
