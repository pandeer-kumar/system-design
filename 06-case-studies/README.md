# Case Studies

## How to practice

1. **Read only the problem statement.** Set a 45-minute timer.
2. **Design it yourself** on paper or a whiteboard using the [framework](../00-interview-framework/01-framework.md).
3. **Then read the solution.** Note what you missed, especially in deep dives and failure handling.
4. **Re-do it a week later** without looking.

Every case study follows the same structure:
- Requirements (functional, non-functional)
- Estimation
- API and data model
- High-level design
- **Deep dives** (the part that matters most)
- Failure modes and edge cases
- Follow-up questions interviewers ask

## Priority order (if time is limited)

**Tier 1, must do** (they cover ~80% of the concepts):
1. [Rate Limiter](02-rate-limiter.md): atomicity, distributed counters
2. [Key-Value Store](03-key-value-store.md): the whole distributed-systems toolkit
3. [News Feed](04-news-feed.md): fan-out, hot users, caching
4. [Chat System](05-chat-system.md): connections, ordering, delivery
5. [Ticket Booking](06-ticket-booking.md): **contention and correctness**
6. [Payment System](07-payment-system.md): **idempotency, ledgers, consistency**
7. [Message Queue](10-message-queue.md): logs, replication, delivery semantics

**Tier 2, very common:**
URL Shortener, Ride Sharing, Video Streaming, Notification System, Web Crawler, Job Scheduler, Flash Sale, Distributed Counter

**Tier 3, differentiators:**
Collaborative Editor, Stock Exchange, Metrics System, File Sync, Typeahead, Proximity, Distributed Cache, Search, Leaderboard

## Concept → case study map

| Concept | Where it's exercised |
|---|---|
| Atomic operations / CAS | Rate Limiter, Ticket Booking, Flash Sale, Counter |
| Distributed locks / leases / fencing | Job Scheduler, Ticket Booking, Ride Sharing |
| Idempotency | Payment, Notification, Message Queue, Chat |
| Single-writer / partition ownership | Stock Exchange, Chat, Collaborative Editor, Flash Sale |
| Consistent hashing | KV Store, Distributed Cache, Chat gateways |
| Quorums, vector clocks, anti-entropy | KV Store |
| Consensus / leader election | Message Queue, Job Scheduler, KV Store (metadata) |
| Sagas / outbox | Payment, Flash Sale, Ride Sharing |
| Fan-out | News Feed, Notification, Chat (groups) |
| Hot keys | News Feed, Counter, Flash Sale, Distributed Cache, Leaderboard |
| Geo-indexing | Ride Sharing, Proximity |
| CRDTs / OT | Collaborative Editor |
| Stream processing | Metrics, Counter, Typeahead (aggregation) |
| CDN / blob storage | Video Streaming, File Sync, URL Shortener |
