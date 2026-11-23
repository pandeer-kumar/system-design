# Concurrency and Distributed Systems Q&A Drill

Cover the answer, say yours out loud, then check. These are the follow-ups interviewers actually ask.

---

## Concurrency (local and database)

**1. What's the difference between a race condition and a data race?**
A data race is unsynchronized concurrent access to memory with at least one write. A race condition is a logic bug where correctness depends on timing. You can have a race condition with no data race (each operation atomic, but the sequence isn't).

**2. Why is `count++` not thread-safe?**
It's load, add, and store: three steps. Two threads can interleave and lose an increment. Use an atomic increment or a lock.

**3. What is CAS, and what's the ABA problem?**
Compare-and-swap atomically sets a value if it equals the expected value. ABA: the value changes A→B→A, so the CAS succeeds even though the state changed. Fix with version stamps.

**4. Four conditions for deadlock? How do you prevent it?**
Mutual exclusion, hold-and-wait, no preemption, circular wait. Prevent with lock ordering, try-lock with timeout, acquiring all locks at once, or lock-free designs.

**5. Optimistic vs pessimistic locking: when to use each?**
Optimistic for low contention and long think time (version check, retry on conflict). Pessimistic for high contention with short critical sections. Extreme contention: neither; restructure with queues or sharding.

**6. Which anomaly does snapshot isolation NOT prevent?**
Write skew (two transactions read overlapping data and write different rows, violating an invariant together).

**7. How do you prevent a lost update in SQL?**
Atomic `UPDATE x = x + 1`, `SELECT ... FOR UPDATE`, a version-column CAS, serializable isolation, or a single writer.

**8. What does `SKIP LOCKED` give you?**
Concurrent workers claim different rows without blocking each other. Ideal for DB-backed job queues and claiming pre-generated inventory units.

**9. What is MVCC, and what's its operational cost?**
Multiple row versions; readers see a snapshot and don't block writers. Cost: old versions need garbage collection (VACUUM). Long transactions cause bloat.

**10. Why can't you hold a DB lock while a user fills in a payment form?**
Locks held for minutes block everyone else and exhaust connections. Use a persisted hold with an expiry instead.

**11. How do you size a thread pool?**
CPU-bound: about the number of cores. I/O-bound: cores × (1 + wait/compute), or Little's Law: throughput × latency. Always bound the queue.

**12. Why is Redis single-threaded, and why is that useful?**
Operations are in-memory and fast, so the bottleneck is the network. A single thread makes every command and Lua script atomic without locks.

**13. What's the "single writer principle"?**
Assign each piece of state exactly one writer (thread, actor, or partition consumer). That removes contention, and ordering follows. Scale by partitioning.

---

## Distributed locks, idempotency, delivery

**14. Why does a distributed lock need a fencing token?**
The holder can pause (GC) past its lease. Another client acquires the lock, the old holder wakes and writes. The storage rejects writes with a token lower than the highest it has seen.

**15. What's wrong with Redlock?**
It depends on timing assumptions (bounded clock drift and pauses) and provides no fencing token. Fine for efficiency locks; not for correctness.

**16. Redis `SET NX PX`: why the random value?**
So you only release your own lock. If your lease expired and someone else got the lock, a plain `DEL` would release theirs. Check-and-delete atomically in Lua.

**17. Is exactly-once delivery possible?**
Not in general (Two Generals). Exactly-once *processing/effect* is: at-least-once delivery plus idempotent processing or dedup, or transactional consume-process-produce (Kafka EOS).

**18. How do idempotency keys work? What are the edge cases?**
Client sends a unique key per logical operation; the server atomically claims it, stores the response, and replays it on retries. Edge cases: the same key with a different payload (422), a concurrent duplicate in flight (409), a crashed in-progress request (recovery points), TTL, and passing your own key to downstream providers.

**19. What is the dual-write problem? Fix?**
Writing to the DB and publishing an event separately can diverge on failure. Fix: transactional outbox (plus CDC relay), with idempotent consumers.

**20. How do you make a Kafka consumer idempotent?**
Dedup table keyed by event ID in the same transaction as the effect; conditional writes; sequence/version checks per entity; or storing offsets atomically with results.

**21. A payment API call times out. What do you do?**
The outcome is unknown. Don't create a new attempt. Retry with the same idempotency key, or query the provider for status; mark it pending; reconcile.

**22. Why retry with jitter?**
Without jitter, clients retry in synchronized waves (a thundering herd). Full jitter spreads them out.

**23. What's a retry budget?**
A cap on retries as a fraction of requests (around 10%), so retries can't multiply load during an outage.

---

## Time and ordering

**24. Why not order events by wall-clock timestamps?**
Clocks skew and jump. A later event can carry an earlier timestamp, so LWW silently loses data.

**25. Lamport clock vs vector clock?**
Lamport gives a total order consistent with causality, but can't detect concurrency. Vector clocks detect concurrency (neither vector dominates).

**26. What does TrueTime do?**
It returns a time interval with bounded uncertainty. Spanner waits out the uncertainty (commit wait) so timestamp order matches real-time order, which gives external consistency.

**27. What's a hybrid logical clock?**
Physical time plus a logical counter. Close to wall time, while preserving causality. Used by CockroachDB and YugabyteDB.

**28. How do you guarantee per-user ordering in Kafka?**
Use user_id as the message key, so it goes to the same partition, with a single consumer per partition. Use an idempotent producer to avoid reordering on retries.

---

## Replication and consistency

**29. Sync vs async replication trade-off?**
Sync: no data loss, higher latency, and it blocks when a replica is down. Async: fast, but recent writes can be lost on failover.

**30. Does W + R > N give linearizability?**
No. Sloppy quorums, concurrent operations, partial failed writes, and LWW clock issues break it. You need synchronous read repair, or a consensus or Paxos path.

**31. What is read-your-writes, and how do you provide it with replicas?**
Users see their own writes. Read from the leader for a window after writing, track the LSN or timestamp and require the replica to be caught up, or use sticky routing.

**32. Linearizability vs serializability?**
Linearizability: single-object real-time recency. Serializability: transactions equivalent to some serial order (not necessarily real time). Both together: strict serializability.

**33. What's the strongest consistency model available under partition?**
Causal consistency (causal+).

**34. Hinted handoff vs read repair vs anti-entropy?**
Hinted handoff: a temporary node stores writes for a down replica and forwards them later. Read repair: fix stale replicas found during reads. Anti-entropy: background Merkle-tree comparison to sync replicas.

**35. How do Merkle trees speed up replica sync?**
Compare root hashes, then recurse only into differing subtrees. Only the mismatched ranges are transferred.

**36. Multi-leader conflict resolution options?**
Avoid conflicts (home region per key), LWW, siblings merged by the app, CRDTs, or custom resolvers.

**37. Why can't CRDTs enforce "stock ≥ 0"?**
Invariants with thresholds are non-monotonic and need coordination. Replicas can each decrement the last item. Use escrow (pre-split quota) or a single leader.

---

## Consensus

**38. Why 2f+1 nodes?**
Majorities intersect, so any two quorums share a node holding the latest committed state. That tolerates f failures.

**39. Why not 4 nodes?**
4 tolerates 1 failure, the same as 3, with more latency and cost.

**40. How does Raft elect a leader safely?**
Randomized election timeouts; a candidate needs a majority of votes; voters only vote for candidates whose log is at least as up to date. One vote per term.

**41. When is a Raft entry committed?**
When the leader has replicated an entry from its current term to a majority. Earlier-term entries commit indirectly.

**42. How do you serve linearizable reads in Raft?**
Pass the read through the log, use ReadIndex (confirm leadership with a heartbeat quorum and wait for apply), or use leader leases (which depend on clock bounds).

**43. What happens to the old leader after a partition heals?**
It sees a higher term, steps down, and its uncommitted entries are overwritten by the new leader's log.

**44. What is PreVote?**
A candidate checks whether it could win before incrementing its term. It prevents a partitioned node from disrupting the cluster when it rejoins.

**45. What is FLP?**
No deterministic algorithm guarantees consensus in an asynchronous system with even one crash failure. Practical protocols are always safe but rely on timeouts for liveness.

**46. Why keep consensus off the data path?**
Consensus is costly (quorum round trips, limited throughput). Use it for metadata and leadership, and replicate data with simpler leader-based schemes fenced by epochs (Kafka, GFS).

---

## Distributed transactions

**47. Why is 2PC blocking?**
If the coordinator crashes after participants vote yes, they're in doubt and must hold locks until it recovers.

**48. How do Spanner and CockroachDB make 2PC practical?**
Participants and the coordinator are Paxos/Raft groups, so they don't "permanently fail," and the in-doubt state survives.

**49. What's a saga, and what's its biggest weakness?**
A sequence of local transactions with compensating actions. Weakness: no isolation, because intermediate states are visible. Countermeasures: semantic locks (PENDING states), and ordering so that the pivot and retriable steps come last.

**50. Choreography vs orchestration?**
Choreography: services react to events, which is loosely coupled but hard to follow. Orchestration: a central coordinator (Temporal) that's explicit and observable. Prefer orchestration for complex flows.

**51. What's TCC?**
Try (reserve), Confirm, Cancel. Business-level 2PC with timeouts on reservations.

---

## Partitioning and scaling

**52. Why does `hash mod N` fail?**
Changing N remaps nearly every key.

**53. What do virtual nodes solve?**
Uneven load distribution, and the problem of a failed node's whole load landing on one neighbour.

**54. How do you handle a hot key?**
Reads: replicate or cache locally, use a CDN. Writes: split into sub-keys (sharded counters), batch, or queue to a single writer. Also detect hot keys.

**55. Local vs global secondary indexes?**
Local: cheap writes, scatter-gather reads. Global: one-partition reads, multi-partition (usually async) writes.

**56. How do you reshard without downtime?**
Many logical shards on fewer physical nodes, so you move whole shards; or dual-write and backfill, then cut over, with consistent hashing to minimize movement.

**57. How do you choose a partition key?**
High cardinality, matches the dominant query, keeps transactional units together, avoids monotonic hot spots, and keeps partition sizes bounded (time buckets).

---

## Caching

**58. Describe the cache-aside stale-set race and its fixes.**
A reader misses and reads the old value from the DB; a writer updates the DB and deletes the cache; the reader then sets the old value. Fixes: leases, delayed double delete, versioned sets, short TTLs, CDC invalidation.

**59. Why delete instead of update the cache on writes?**
Concurrent updates can apply out of order and leave a stale value. Deletes are idempotent and order-insensitive.

**60. What's a cache stampede? Fixes?**
A hot key expires and many requests recompute it at once. Fixes: single-flight, a lock on recompute, stale-while-revalidate, probabilistic early refresh, TTL jitter.

**61. Penetration vs breakdown vs avalanche?**
Penetration: requests for nonexistent keys (fix with negative caching or a Bloom filter). Breakdown: one hot key expiring (single-flight). Avalanche: mass expiry or a cache cluster outage (jitter, HA, rate limiting).

---

## Messaging

**62. Queue vs log?**
A queue deletes on ack and supports per-message retry and delay. A log retains messages, supports replay and multiple consumer groups, and orders per partition.

**63. What is Kafka's ISR, and why `min.insync.replicas`?**
ISR is the set of replicas caught up with the leader. `acks=all` waits for the ISR; `min.insync.replicas=2` rejects writes if the ISR shrinks below 2, which prevents silent single-copy writes.

**64. What's the high watermark?**
The offset replicated to all ISR members. Consumers can only read up to it.

**65. How do you handle a poison message in Kafka?**
Retry topics with delays, then a DLQ after N attempts. If per-key ordering matters, park later messages for that key.

**66. Why can't you just add partitions to a Kafka topic?**
Key → partition mapping changes, which breaks ordering for existing keys. And partitions can't be removed.

**67. Consumer lag: why is it the key metric?**
It shows whether consumers keep up. Growing lag means delayed processing, and eventually data loss if lag exceeds retention.

---

## Resilience

**68. Circuit breaker states?**
Closed (normal), Open (fail fast), Half-open (trial requests).

**69. Bulkhead?**
Isolated resource pools per dependency or tenant, so one failure can't exhaust everything.

**70. Backpressure vs load shedding?**
Backpressure slows producers down. Load shedding drops excess requests to protect latency for the rest.

**71. What's a metastable failure?**
A failure state that sustains itself after the trigger is gone (retry storms, cold caches). Recovery needs drastic load reduction.

**72. Shuffle sharding?**
Each customer is assigned a random subset of workers. One bad customer affects few others, because customers rarely share the exact same subset.

**73. Static stability?**
The system keeps working through a dependency failure without needing to make changes (pre-provisioned capacity, cached config).

**74. Why are hedged requests useful, and when are they dangerous?**
They cut tail latency by sending a duplicate after the p95 delay. Dangerous for non-idempotent operations and under overload (they add load). Budget them.

---

## Scenario rapid-fire

**75. Two users book the last seat simultaneously.**
Conditional update `WHERE status='AVAILABLE'` (or a unique constraint). Exactly one succeeds. Hold with expiry, then confirm on payment.

**76. A flash sale with 1M requests/s for 10K items.**
Reject early (CDN, rate limits, a sold-out flag), an atomic Redis decrement (Lua) or token claims, an async order queue, and a DB conditional update as the final guard.

**77. A like counter on a viral post.**
A unique (post, user) row for correctness; the aggregate count via sharded counters or stream batching; cached reads.

**78. A cron job must run exactly once across 3 instances.**
Partition leases or leader election with fencing, a unique (job, scheduled_time) run row, and idempotent jobs.

**79. Chat messages arrive out of order.**
Per-conversation sequence numbers assigned by a single owner or an atomic counter; clients sort and detect gaps; sync from a cursor.

**80. A user updates their profile but sees the old one.**
Read-your-writes: read from the leader after writes, or LSN tracking.

**81. Elasticsearch drifts out of sync with the DB.**
CDC-driven indexing with external versioning, plus a periodic full reindex with an alias swap.

**82. A Redis primary failed over and the rate limiter reset some counts.**
Async replication loss. Accept brief over-admission for rate limits; never rely on Redis for correctness-critical state without a DB guard.

**83. A network partition splits a 5-node Raft cluster 2/3.**
The 3-node side elects a leader and continues. The 2-node side can't commit and returns errors or redirects. On heal, the minority catches up.

**84. A service has 6 synchronous downstream calls and p99 latency is terrible.**
Parallelize independent calls, cache, set timeouts with fallbacks, hedge idempotent reads, make non-critical calls async, and reduce fan-out.

**85. Money transfer between accounts on different shards.**
Use a distributed SQL DB's transactions, or a saga with a ledger: debit with a pending entry, credit idempotently, compensate on failure, and reconcile.

**86. Multi-region active-active with a username uniqueness constraint.**
Route username claims to a single authority (a home region or a globally consistent store like Spanner). LWW global tables would allow duplicates.

**87. A webhook receiver gets duplicate and out-of-order events.**
Dedupe by event ID; use event sequence numbers or versions, or fetch the latest state from the API on each event.

**88. A cache cluster restarts at peak and the DB melts.**
Warm-up before taking traffic, rate limiting of misses, stale-while-revalidate, request coalescing, a gutter pool, and load shedding.

**89. One tenant generates 50% of the load and hurts others.**
Per-tenant rate limits and quotas, shuffle sharding or cells, a dedicated shard for that tenant, and priority queues.

**90. How would you detect that your system is silently losing data?**
Reconciliation jobs (source vs derived counts), end-to-end checksums, synthetic canary records written and read back, business metrics anomaly detection, and audit logs.

---

## Senior judgement questions

**91. When would you NOT use microservices?**
Small team, unclear domain boundaries, early product, or strong transactional coupling. Start with a modular monolith.

**92. When would you NOT use Kafka?**
Low volume, simple job queues needing per-message retry or delay, or a team without the capacity to operate it. Use SQS, or Postgres with `SKIP LOCKED`.

**93. When is eventual consistency unacceptable?**
Money movement, inventory invariants, uniqueness, authorization revocations (be careful), and leader election and locks.

**94. How do you choose between building and buying (managed services)?**
Core differentiator vs commodity, scale economics, team expertise, lock-in, and compliance.

**95. How would you migrate a monolith's DB to sharded storage without downtime?**
Dual writes behind a flag (or CDC), backfill, shadow reads that compare results, gradual read cutover, stop the old writes, and decommission.

**96. What's the most common cause of outages, and how do you design for it?**
Changes. Staged rollouts, feature flags, automated rollback, config validation, and small blast radius (cells).

**97. How do you design for a 10× traffic increase in 6 months?**
Find the first bottleneck (usually the DB or a hot partition), add caching, shard, make work async, load test, and capacity-plan with headroom.

**98. How do you decide timeouts?**
From the dependency's latency distribution (about p99.9) within the caller's deadline budget, with deadline propagation.

**99. What's your approach when the interviewer says "assume the cache is down"?**
Show degradation: the DB absorbs traffic with rate limiting, stale or default responses, shedding non-critical features, and circuit breakers. Discuss whether the cache is load-bearing.

**100. What would you monitor first for a new design?**
SLO-based RED metrics at the edge, queue lag, replication lag, error budget burn, key business metrics, and reconciliation drift.
