# Trade-off Tables

Quick reference for the decisions that come up in every interview.

## Consistency vs availability vs latency

| Choose | Gain | Pay |
|---|---|---|
| Linearizable | Correctness, simple reasoning | Latency (quorum round trips), unavailability during partitions |
| Causal / session | Intuitive UX, available | Tracking metadata; not for invariants |
| Eventual | Lowest latency, highest availability | Stale reads, conflict resolution |

## Concurrency control

| Approach | Best when | Avoid when |
|---|---|---|
| Atomic op (`x = x + 1 WHERE x > 0`, INCR) | Simple counters/decrements | Complex multi-step logic |
| Optimistic (version/CAS) | Low conflict rate, long think time | High contention (retry storms) |
| Pessimistic (`FOR UPDATE`) | High contention on few rows, short transactions | Long operations, cross-service |
| Unique constraint | Uniqueness/claims | Ranges/overlaps (use exclusion constraints or slots) |
| Distributed lock + fencing | Exclusive access to a resource outside one DB | Anything a conditional write can do |
| Single writer (partition/actor) | Extreme contention, ordering needed | Low-traffic entities (overhead) |
| Queue / admission control | Spikes far beyond capacity | Synchronous answers required immediately |
| CRDT | Multi-writer, mergeable data | Invariants (stock ≥ 0, uniqueness) |

## Fan-out

| | Write (push) | Read (pull) | Hybrid |
|---|---|---|---|
| Read latency | Fast | Slow | Fast |
| Write cost | High (× followers) | Low | Medium |
| Celebrities | Breaks | Fine | Pull for celebrities |
| Freshness | Lag | Fresh | Mixed |

## Replication

| | Single-leader | Multi-leader | Leaderless |
|---|---|---|---|
| Write conflicts | None | Yes | Yes |
| Write availability | Leader-dependent | High | High |
| Consistency | Strong possible | Eventual | Tunable |
| Complexity | Low | High | Medium |

## Sync vs async replication

| | Sync | Async |
|---|---|---|
| RPO | 0 | > 0 (lost writes) |
| Write latency | + replica RTT | Unaffected |
| Availability | Blocks if replica down | Unaffected |

## Partitioning

| | Range | Hash | Compound (hash + sort) |
|---|---|---|---|
| Range scans | ✅ | ❌ | ✅ within partition |
| Hot spots | Sequential keys | Hot single keys | Hot single keys |
| Rebalancing | Split/merge | Consistent hashing / fixed partitions | Same as hash |

## Storage engines

| | B-Tree | LSM |
|---|---|---|
| Reads | Faster | Slower (multiple levels) |
| Writes | Slower (random I/O) | Faster (sequential) |
| Space | Fragmentation | Compaction overhead |

## SQL vs NoSQL

| | Relational | NoSQL (KV / wide-column / document) |
|---|---|---|
| Schema | Strict | Flexible |
| Queries | Ad hoc, joins | Pre-planned access patterns |
| Transactions | Rich ACID | Limited (single-partition, or costly) |
| Scale-out writes | Hard (sharding) | Built in |
| Default for | Most business data | Huge scale, simple access patterns, high write throughput |

## Messaging

| | Queue (SQS/RabbitMQ) | Log (Kafka) |
|---|---|---|
| Replay | ❌ | ✅ |
| Per-message ack/retry/delay | ✅ | ❌ |
| Ordering | FIFO groups | Per partition |
| Multiple consumers | Fan-out via exchanges/SNS | Consumer groups |
| Throughput | High | Very high |

## Communication

| | Sync (REST/gRPC) | Async (events/queues) |
|---|---|---|
| Coupling | Temporal coupling | Decoupled |
| Latency | Immediate answer | Eventual |
| Failure | Cascades | Absorbed (with lag) |
| Debugging | Easier | Harder (needs tracing) |

## Real-time delivery

| | Polling | Long polling | SSE | WebSocket |
|---|---|---|---|---|
| Direction | Client pull | Client pull | Server push | Bidirectional |
| Overhead | High | Medium | Low | Lowest |
| Complexity | Lowest | Low | Low | Medium (stateful) |

## Caching strategies

| | Cache-aside | Write-through | Write-behind |
|---|---|---|---|
| Read miss cost | 3 trips | Rare | Rare |
| Write latency | DB only | DB + cache | Cache only |
| Staleness risk | Some | Low | Low (but data loss risk) |
| Data loss risk | None | None | Yes |

## Distributed transactions

| | 2PC | Saga | Outbox + idempotent consumers |
|---|---|---|---|
| Atomicity | Strong | Eventual (compensations) | Eventual |
| Isolation | Yes (locks) | No | No |
| Availability | Blocks on coordinator failure | High | High |
| Complexity | Protocol + participants | Compensation logic | Low–medium |

## Monolith vs microservices

| | Monolith | Microservices |
|---|---|---|
| Speed early | ✅ | ❌ |
| Team scaling | ❌ | ✅ |
| Ops overhead | Low | High |
| Transactions | Easy | Sagas |
| Failure isolation | Low | High (if designed for it) |
