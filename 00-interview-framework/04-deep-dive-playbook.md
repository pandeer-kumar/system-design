# The Deep-Dive Playbook

> At senior and staff levels, the high-level diagram earns you very little; it's the 15–20 minutes of deep dives that decide the outcome. This page is a method for running them, plus a map of the deep dives that come up most often for each common question.

## 1. What interviewers are actually scoring in a deep dive

1. **Problem framing:** can you state precisely what goes wrong (the race, the hot key, the failure) before proposing fixes?
2. **Options and trade-offs:** do you know 2–3 real alternatives, and can you compare them on the dimensions that matter here?
3. **Mechanism depth:** can you explain how the chosen component works inside, at least one level below its API?
4. **Failure reasoning:** what happens when it times out, crashes mid-way, is retried, or races?
5. **Judgement:** do you pick an answer and justify it with the requirements, instead of listing everything?

## 2. The 5-step deep-dive loop

Use this every time:

```
1. PROBLEM   "At 50K requests/s on one event, two users can both read 'available' and both book seat A12."
2. OPTIONS   "Three options: row lock, conditional update, or a single writer per event."
3. COMPARE   "Locks block under contention; conditional updates are one statement with no lock held
              across round trips; single writer removes contention but needs failover."
4. DECIDE    "Conditional update, because ... For the mega on-sale, a waiting room in front."
5. BREAK IT  "What if the payment succeeds after the hold expired? → compensate with a refund;
              what if the confirm is retried? → idempotent by hold_id."
```

Step 5 is what separates strong candidates. Volunteer the failure cases before the interviewer asks.

## 3. Going three levels deep on any component

Interviewers drill down until you run out of depth. Prepare three levels for each technology you name:

| Component | Level 1 (what) | Level 2 (how) | Level 3 (edge cases and failure) |
|---|---|---|---|
| Kafka | Partitioned log, consumer groups | ISR, HW, leader epoch, offsets in `__consumer_offsets` | Unclean election, rebalance storms, lag beyond retention, EOS via transactions |
| Redis | In-memory KV, data structures | Single-threaded event loop, RDB/AOF, async replication, 16,384 slots | Lost writes on failover, fork latency, hot/big keys, `MOVED`/`ASK` |
| Postgres | ACID SQL | MVCC xmin/xmax, WAL, VACUUM, isolation levels | XID wraparound, replication slot disk fill, write skew, DDL lock queues |
| Cassandra | Wide-column, tunable consistency | Commit log + memtable + SSTables, quorums, hinted handoff | Tombstones, repair within gc_grace, partition size, LWT cost |
| DynamoDB | Managed KV | Partitions (3K RCU/1K WCU/10 GB), GSIs async, conditional writes | Hot key throttling, GSI back-pressure, LWW global tables |
| Elasticsearch | Search engine | Translog, refresh → segments, primary-replica, query-then-fetch | Oversharding, mapping explosion, deep pagination, not a source of truth |
| ZooKeeper/etcd | Coordination | Consensus, sessions/leases, watches, revisions | Stale ZK reads, session expiry during GC, fencing, data size limits |
| SQS/RabbitMQ | Task queues | Visibility timeout / acks + prefetch, DLQ | Task longer than the timeout → double run; poison messages; FIFO group blocking |
| Flink | Stream processor | Event time, watermarks, keyed state, checkpoints | Late data, idle partitions stalling watermarks, hot keys, 2PC sinks |
| CDN | Edge cache | Cache keys, TTLs, origin shield | Purge latency, cache stampede on a viral miss, personalized content |

The [Technology Deep Dives](../09-technology-deep-dives/README.md) section covers each of these.

## 4. Likely deep dives by question

| Question | Deep dives interviewers usually push on |
|---|---|
| URL shortener | ID generation without collisions; hot links; analytics without slowing redirects |
| Rate limiter | Atomicity (Lua), multi-region accuracy vs latency, fail-open vs fail-closed |
| News feed | Fan-out on write vs read, celebrities, cache structure, ranking latency budget |
| Chat | Connection routing, per-conversation ordering, delivery guarantees and sync, group fan-out, presence |
| Ticket booking | **Double-booking prevention**, hold expiry, payment-after-expiry, flash crowd admission |
| Payments | **Idempotency end to end**, unknown outcomes from the PSP, ledger invariants, reconciliation |
| Ride sharing | Geo index under 250K updates/s, **driver double-assignment**, dispatch partitioning |
| Video streaming | Parallel transcoding DAG, ABR + CDN strategy, view counting |
| Message queue / Kafka | Replication (ISR/HW/epoch), ordering, delivery semantics, consumer rebalancing |
| Task queue / SQS | Visibility timeout mechanics, at-least-once + idempotency, delayed messages, FIFO groups, fairness |
| Job scheduler | Exactly-once triggering (unique run rows + leases), worker failure, the midnight herd |
| KV store | Partitioning, quorums, conflict resolution (vector clocks vs LWW), repair |
| Distributed cache | Consistency with DB (leases), hot keys, failover (gutter pools) |
| Collaborative editor | OT vs CRDT, single owner per document, offline merge |
| Web crawler | Politeness with a host-partitioned frontier, dedup at billions, traps |
| Notifications | Priority isolation, dedup, provider failures, campaign throttling |
| Ad click aggregation | Event time + watermarks, exactly-once counting, hot ads, batch reconciliation for billing |
| Top-K / trending | Exact vs approximate (CMS), correct distributed merge, sliding windows |
| Object storage (S3) | Metadata/data split, erasure coding placement, consistency of LIST, GC |
| Metrics system | Write path at 10M points/s, compression, cardinality limits, alerting HA |
| Stock exchange | Single-threaded deterministic matching, sequencer, replication by replay |
| Search | Indexing pipeline via CDC, shard sizing, scatter-gather tail latency |

## 5. Phrases that open a good deep dive

- "Let me make the failure concrete first: ..."
- "There are three ways to solve this; let me compare them on consistency, latency, and operational cost."
- "Here's what happens inside Kafka when the leader dies at this exact moment ..."
- "The invariant we must never violate is ___. Here's every path that could violate it, and what stops each one."
- "Let's say this call times out. We don't know whether it succeeded. So ..."
- "This works until one key gets 20% of the traffic. Then ..."

## 6. When you don't know the internal detail

Don't bluff. Reason from the property you need:

> "I don't remember whether Elasticsearch replicas acknowledge before or after refresh, but what I need is that an acknowledged write survives a node loss. I'd verify that the write waits for in-sync replicas and that the translog is fsync'd per request, and if not, I'd treat ES as rebuildable from the database via CDC anyway."

That shows judgement, which is what's being scored.

## 7. Practising deep dives

1. For each case study, write down the **invariant** (e.g., "a seat is sold at most once") and list **every way it could be violated** (races, retries, crashes, failover, clock skew). Then the mechanism that stops each.
2. For each technology in the table above, explain levels 1–3 out loud in under 3 minutes each.
3. Use the [Q&A drill](../08-cheatsheets/05-qa-drill.md) for rapid recall.
4. Do mock interviews where the other person only asks "why?" and "what if it fails?"
