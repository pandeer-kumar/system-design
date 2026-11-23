# Interview Day Checklist and Common Mistakes

## Before the interview

- [ ] Practiced 10+ case studies end to end under a 45-minute timer
- [ ] Can draw from memory: consistent hashing ring, Raft log replication, Kafka partitions/ISR, cache-aside with races, 2PC vs saga, idempotency key flow, outbox
- [ ] Know the numbers sheet
- [ ] Have 3–4 real incidents/papers ready to cite
- [ ] Whiteboard tool practiced (Excalidraw, a Google Drawing, or the company's tool)

## During: the checklist

**Requirements (5 min)**

- [ ] Functional: 3–5 core features, explicit out-of-scope
- [ ] Scale: DAU, QPS (avg/peak), data size, read:write ratio
- [ ] Latency and availability targets
- [ ] **Consistency per operation**
- [ ] Hot spots / contention expected? (celebrities, flash sales, viral content)

**Estimation (3–5 min)**

- [ ] Only the numbers that drive decisions
- [ ] Peak, not just average

**API + data (5 min)**

- [ ] Endpoints with idempotency where needed
- [ ] Entities + **access patterns** → partition keys

**High-level (10 min)**

- [ ] Walk one read and one write request end to end
- [ ] Every functional requirement covered

**Deep dives (15–20 min)**: pick the hardest 2–3

- [ ] Concurrency/contention resolution
- [ ] Scaling the bottleneck (fan-out, hot keys, sharding)
- [ ] Consistency across components (outbox, saga, cache invalidation)
- [ ] Failure handling (what if X dies, times out, or is slow?)

**Wrap-up (3–5 min)**

- [ ] Bottlenecks at 10×
- [ ] Failure modes + mitigations
- [ ] Monitoring: SLOs, key metrics, alerts
- [ ] What you'd do with more time

## The questions to ask yourself at every component

1. What happens when it **fails**?
2. What happens when it's **slow**?
3. What happens when a request is **retried**?
4. What happens when two requests **race**?
5. What happens at **10× load**? On a **hot key**?
6. How do we **know** it's broken?

## Top 20 mistakes

1. Diving into the solution without clarifying requirements
2. Over-long estimation
3. Technology-first thinking ("let's use Kafka") without a requirement
4. No API or data model
5. Ignoring the read/write ratio and access patterns
6. Designing only the happy path
7. Saying "use a distributed lock" without leases and fencing
8. Assuming exactly-once delivery
9. Retries without idempotency
10. Dual writes (DB + queue/cache/search) without an outbox or CDC
11. Using wall-clock time for ordering
12. Ignoring hot keys and celebrity users
13. "Strong consistency everywhere" or "eventual everywhere," instead of per operation
14. Forgetting cache invalidation races and stampedes
15. Synchronous chains of many services
16. No backpressure or load shedding, with unbounded queues
17. Not discussing monitoring
18. Over-engineering (multi-region active-active without a requirement)
19. Not checking in with the interviewer; monologuing for 20 minutes
20. Getting defensive when challenged

## Phrases for when you're stuck

- "Let me think about the failure modes of this for a second."
- "There are two ways to do this; let me compare them quickly."
- "I'm not certain about that internal detail of X, but the property I need is Y, and here's how I'd verify X provides it."
- "Let me step back. What's the actual bottleneck here?"
