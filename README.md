# System Design: The Complete Guide (HLD, Concurrency, Distributed Systems)

A guide for senior/staff-level FAANG system design interviews, written to be the only resource you need. It has a strong focus on **concurrency** and **distributed systems**, because that's where senior candidates are separated from mid-level ones.

> Interviewers don't check whether you remember an architecture diagram. They check whether you can **reason about trade-offs under constraints**: what breaks, when, why, and what you would do about it. Every chapter here is written with that in mind.

---

## How to use this guide

| Phase | Time | What to do |
|---|---|---|
| 1. Foundation | Week 1–2 | Read `00` → `03` in order. Don't skip concurrency or distributed systems. |
| 2. Building blocks | Week 3 | Read `04`. For each component, be able to explain internals, not just usage. |
| 3. Patterns | Week 4 | Read `05`. These are the vocabulary of senior answers. |
| 4. Case studies | Week 5–7 | Read `06`. Do each one **yourself first** (45 min, whiteboard), then compare. |
| 5. Real-world | Ongoing | Read `07` (papers + outages). This is what makes answers sound experienced. |
| 6. Revision | Last week | `08` cheat sheets plus re-doing 5 case studies under time pressure. |

---

## Table of contents

### [00 — Interview Framework](00-interview-framework/)
- [01 — The 45-minute framework](00-interview-framework/01-framework.md)
- [02 — Back-of-the-envelope estimation](00-interview-framework/02-estimation.md)
- [03 — What senior/staff signals look like](00-interview-framework/03-senior-signals.md)

### [01 — Fundamentals](01-fundamentals/)
- [01 — Scalability, availability, reliability, latency](01-fundamentals/01-core-qualities.md)
- [02 — Networking for system design (TCP, HTTP/2/3, gRPC, WebSockets, DNS)](01-fundamentals/02-networking.md)
- [03 — CAP, PACELC, and what they actually mean](01-fundamentals/03-cap-pacelc.md)
- [04 — API design (REST, gRPC, GraphQL, pagination, idempotency)](01-fundamentals/04-api-design.md)

### [02 — Concurrency](02-concurrency/) ⭐
- [01 — Concurrency fundamentals (threads, races, memory models)](02-concurrency/01-fundamentals.md)
- [02 — Locks, synchronization primitives, deadlocks](02-concurrency/02-locks-and-sync.md)
- [03 — Database concurrency: isolation levels, MVCC, anomalies](02-concurrency/03-database-concurrency.md)
- [04 — Optimistic vs pessimistic concurrency control](02-concurrency/04-optimistic-vs-pessimistic.md)
- [05 — Distributed locks, leases, and fencing tokens](02-concurrency/05-distributed-locks.md)
- [06 — Idempotency and exactly-once semantics](02-concurrency/06-idempotency.md)
- [07 — Concurrency models: threads, event loops, actors, async](02-concurrency/07-concurrency-models.md)
- [08 — Classic concurrency problems in system design](02-concurrency/08-classic-problems.md)

### [03 — Distributed Systems](03-distributed-systems/) ⭐
- [01 — Fallacies, failure modes, and the reality of networks](03-distributed-systems/01-failure-modes.md)
- [02 — Time, clocks, and ordering (Lamport, vector clocks, HLC, TrueTime)](03-distributed-systems/02-time-and-ordering.md)
- [03 — Replication (leader, multi-leader, leaderless, quorums)](03-distributed-systems/03-replication.md)
- [04 — Partitioning/sharding and consistent hashing](03-distributed-systems/04-partitioning.md)
- [05 — Consistency models (linearizable → eventual)](03-distributed-systems/05-consistency-models.md)
- [06 — Consensus (Paxos, Raft, ZAB) and leader election](03-distributed-systems/06-consensus.md)
- [07 — Distributed transactions (2PC, 3PC, Sagas, Outbox)](03-distributed-systems/07-distributed-transactions.md)
- [08 — Conflict resolution and CRDTs](03-distributed-systems/08-crdts-conflict-resolution.md)
- [09 — Membership, failure detection, gossip](03-distributed-systems/09-membership-gossip.md)

### [04 — Building Blocks](04-building-blocks/)
- [01 — Load balancing and proxies](04-building-blocks/01-load-balancing.md)
- [02 — Caching (strategies, invalidation, stampedes)](04-building-blocks/02-caching.md)
- [03 — Databases: choosing SQL vs NoSQL, storage engines (B-Tree vs LSM)](04-building-blocks/03-databases.md)
- [04 — Message queues and streaming (Kafka, SQS, RabbitMQ)](04-building-blocks/04-messaging.md)
- [05 — Blob storage, CDN, and file systems](04-building-blocks/05-storage-cdn.md)
- [06 — Search and indexing](04-building-blocks/06-search.md)
- [07 — Unique ID generation](04-building-blocks/07-id-generation.md)
- [08 — Rate limiting algorithms](04-building-blocks/08-rate-limiting.md)
- [09 — Observability (metrics, logs, traces, SLOs)](04-building-blocks/09-observability.md)

### [05 — Patterns](05-patterns/)
- [01 — Resilience patterns (timeouts, retries, circuit breakers, bulkheads, backpressure)](05-patterns/01-resilience.md)
- [02 — Event-driven architecture, CQRS, event sourcing](05-patterns/02-event-driven.md)
- [03 — Microservices, service discovery, service mesh](05-patterns/03-microservices.md)
- [04 — Multi-region and disaster recovery](05-patterns/04-multi-region.md)
- [05 — Data processing: batch, stream, lambda/kappa](05-patterns/05-data-processing.md)
- [06 — Security for system design](05-patterns/06-security.md)

### [06 — Case Studies](06-case-studies/) ⭐ Must-read
| # | Case study | Core lessons |
|---|---|---|
| 01 | [URL Shortener](06-case-studies/01-url-shortener.md) | ID generation, read-heavy caching, the warm-up problem |
| 02 | [Distributed Rate Limiter](06-case-studies/02-rate-limiter.md) | Atomic counters, Lua/Redis, races, multi-region |
| 03 | [Distributed Key-Value Store (Dynamo)](06-case-studies/03-key-value-store.md) | Consistent hashing, quorums, vector clocks, anti-entropy |
| 04 | [News Feed (Twitter/Instagram)](06-case-studies/04-news-feed.md) | Fan-out on write vs read, the celebrity problem |
| 05 | [Chat System (WhatsApp/Messenger)](06-case-studies/05-chat-system.md) | Connections at scale, ordering, delivery receipts |
| 06 | [Ticket Booking (Ticketmaster/BookMyShow)](06-case-studies/06-ticket-booking.md) | **Contention, seat holds, oversell prevention** |
| 07 | [Payment System (Stripe)](06-case-studies/07-payment-system.md) | **Idempotency, double-entry ledger, reconciliation** |
| 08 | [Ride Sharing (Uber/Lyft)](06-case-studies/08-ride-sharing.md) | Geo-indexing, matching under concurrency, location firehose |
| 09 | [Video Streaming (YouTube/Netflix)](06-case-studies/09-video-streaming.md) | Transcoding pipeline, CDN, adaptive bitrate |
| 10 | [Distributed Message Queue (Kafka)](06-case-studies/10-message-queue.md) | Log replication, ISR, consumer groups, exactly-once |
| 11 | [Distributed Job Scheduler](06-case-studies/11-job-scheduler.md) | Leader election, at-least-once execution, leases |
| 12 | [Collaborative Editor (Google Docs)](06-case-studies/12-collaborative-editor.md) | OT vs CRDT, real-time sync |
| 13 | [Web Crawler](06-case-studies/13-web-crawler.md) | URL frontier, politeness, dedup at scale |
| 14 | [Notification System](06-case-studies/14-notification-system.md) | Fan-out, priority, dedup, third-party failures |
| 15 | [Typeahead / Autocomplete](06-case-studies/15-typeahead.md) | Tries, precomputation, latency budgets |
| 16 | [File Sync (Dropbox/Google Drive)](06-case-studies/16-file-sync.md) | Chunking, dedup, sync conflicts |
| 17 | [Stock Exchange / Matching Engine](06-case-studies/17-stock-exchange.md) | Single-threaded determinism, sequencers, low latency |
| 18 | [Metrics & Monitoring System](06-case-studies/18-metrics-monitoring.md) | Time-series storage, high-cardinality writes |
| 19 | [Distributed Counter / Likes / View Count](06-case-studies/19-distributed-counter.md) | Hot keys, sharded counters, approximate counting |
| 20 | [Inventory / Flash Sale (Amazon)](06-case-studies/20-flash-sale.md) | **Extreme contention, queues as admission control** |
| 21 | [Proximity Service (Yelp/Nearby Friends)](06-case-studies/21-proximity-service.md) | Geohash, quadtree, S2 |
| 22 | [Distributed Cache (Memcached/Redis Cluster)](06-case-studies/22-distributed-cache.md) | Sharding, replication, hot keys, eviction |
| 23 | [Search Engine / Log Search](06-case-studies/23-search-system.md) | Inverted index, sharding, scatter-gather |
| 24 | [Leaderboard / Gaming](06-case-studies/24-leaderboard.md) | Sorted sets, real-time ranking at scale |

### [07 — Real World](07-real-world/)
- [01 — Papers every senior engineer should know (summarized)](07-real-world/01-papers.md)
- [02 — Famous outages and what they teach](07-real-world/02-outages-postmortems.md)
- [03 — How big companies actually built it](07-real-world/03-company-architectures.md)

### [08 — Cheat Sheets](08-cheatsheets/)
- [01 — Numbers every engineer should know](08-cheatsheets/01-numbers.md)
- [02 — Trade-off tables](08-cheatsheets/02-tradeoffs.md)
- [03 — Technology picker](08-cheatsheets/03-technology-picker.md)
- [04 — Interview day checklist and common mistakes](08-cheatsheets/04-interview-checklist.md)
- [05 — Concurrency and distributed systems Q&A drill (100+ questions)](08-cheatsheets/05-qa-drill.md)

---

## The 10 ideas that matter most

If you remember nothing else, remember these:

1. **Everything is a trade-off.** Say the trade-off out loud: "I'm choosing X, which costs us Y, and that's fine because Z."
2. **Networks fail, clocks lie, and processes pause.** Design for partial failure.
3. **Retries need idempotency.** A retry without an idempotency key is a bug waiting to happen.
4. **Contention is the enemy of scale.** Shard it, queue it, or redesign so you don't need it.
5. **Lock-free beats locks, and no sharing beats lock-free.** Partition the data so a single owner handles each piece.
6. **Pick a consistency level per operation, not per system.** A bank balance and a like count need different guarantees.
7. **Caches are a consistency problem in disguise.**
8. **Queues absorb spikes but hide latency and failures.** Watch the lag.
9. **The hot key or hot partition is the thing that kills you in production.** Plan for skew.
10. **You can't fix what you can't see.** Mention metrics, alerts, and SLOs in every design.
