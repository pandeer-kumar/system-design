# The 45-Minute System Design Framework

The interview is a **collaborative design review**, not a quiz. You are the tech lead running it, and the interviewer is a stakeholder who also happens to know where the bodies are buried.

## Time budget (45–60 min)

| Step | Time | Output |
|---|---|---|
| 1. Clarify requirements | 5–7 min | Functional + non-functional requirements, explicit scope |
| 2. Estimate scale | 3–5 min | QPS, storage, bandwidth, read:write ratio |
| 3. API + data model | 5 min | Core endpoints, entities, access patterns |
| 4. High-level design | 10 min | Boxes and arrows that satisfy every functional requirement |
| 5. Deep dives | 15–20 min | 2–3 hardest problems solved properly |
| 6. Wrap-up | 3–5 min | Bottlenecks, failure modes, monitoring, future work |

---

## Step 1: Clarify requirements

**Functional:** what must the system *do*? Pick the 3–5 core features and say explicitly what's out of scope.

> "For a ride-sharing app I'll focus on: rider requests a ride, matching to a nearby driver, live location tracking, and trip completion. I'll leave out payments, ratings, and surge pricing unless we have time. Does that work?"

**Non-functional:** this is where the interesting design comes from. Always ask about:

- **Scale:** DAU, peak QPS, data volume, growth rate
- **Latency:** p50/p99 targets ("feed loads in <200ms p99")
- **Availability:** 99.9% (8.7h/yr down) vs 99.99% (52 min/yr)
- **Consistency:** can a user see stale data? For how long? Which operations need strong consistency?
- **Durability:** can we ever lose data? (Payments: never. Typing indicators: who cares.)
- **Read vs write ratio**
- **Geography:** single region or global? Data residency?
- **Concurrency profile:** are there hot spots? (Celebrity accounts, flash sales, viral content)

**Senior move:** turn requirements into numbers and constraints that *drive* design decisions.
"Since we need 99.99% availability and global users, we'll need multi-region, and that means we have to decide what happens to writes during a region partition."

## Step 2: Estimate

See [02-estimation.md](02-estimation.md). Only estimate what changes a decision:

- Does it fit on one machine? (storage, memory, QPS)
- Do we need sharding? How many shards?
- Can the cache hold the working set?
- What's the bandwidth at peak?

## Step 3: API and data model

```
POST /v1/rides            {rider_id, pickup, dropoff, idempotency_key} -> {ride_id}
GET  /v1/rides/{id}       -> {status, driver, eta}
WS   /v1/drivers/location  stream {lat, lng, ts}
```

Then the core entities and, more importantly, the **access patterns**:

- "Get all rides for a rider, newest first" → partition by rider_id, sort by created_at desc
- "Find drivers within 2km" → geo index

The access patterns pick the database, not the other way around.

## Step 4: High-level design

Draw the simplest design that satisfies every functional requirement. Walk through **one request end to end**.

```
Client → CDN → LB → API Gateway → Service(s) → Cache → DB
                                       ↓
                                    Queue → Workers → (Search, Notifications, Analytics)
```

Don't over-engineer yet. Say: "This works at small scale. Now let's find where it breaks."

## Step 5: Deep dives (where senior candidates win)

Pick the 2–3 hardest problems. Often the interviewer steers you, but **proactively propose** them:

> "The two hardest parts here are (1) preventing double-booking when 10,000 people hit the same seat, and (2) keeping the seat map fresh without hammering the DB. Want me to start with the first one?"

For each deep dive:

1. State the problem precisely, including the failure scenario
2. Give 2–3 options
3. Compare them on the dimensions that matter (consistency, latency, complexity, cost)
4. Pick one and justify it
5. Say how it fails and how you'd detect that

Common deep-dive themes:

- **Concurrency/contention:** double-booking, inventory, counters, ordering
- **Hot spots:** celebrity users, viral content, hot partitions
- **Consistency across services:** distributed transactions, outbox, sagas
- **Failure handling:** region down, DB failover, partial writes, retries
- **Scale bottleneck:** fan-out, write amplification, index size
- **Latency:** caching layers, precomputation, geo-distribution

## Step 6: Wrap-up

- **Bottlenecks:** "At 10x, the first thing to break is X."
- **Failure modes:** "If Redis dies, we fall back to Y and accept Z."
- **Observability:** key metrics, SLOs, alerts
- **Operations:** deployments, migrations, backfills
- **Evolution:** what you'd do with more time

---

## Communication rules

1. **Think out loud.** Silence is a negative signal.
2. **Drive.** Don't wait to be asked "what next?".
3. **Check in** every 5–10 min: "Does this level of detail work, or should I go deeper here?"
4. **Write numbers down.** Keep the estimates visible.
5. **Name your trade-offs.** "I'm picking eventual consistency for likes because a stale count is harmless, and it lets us avoid a hot row."
6. **Don't name-drop without reasons.** "Use Kafka" is weak. "Use a partitioned log so we get per-key ordering and replay, and Kafka is the standard choice" is strong.
7. **When challenged, consider it honestly.** The interviewer is often testing whether you can update your design, not trying to trick you.
8. **Draw the data flow, not just the boxes.** Number the arrows: 1, 2, 3...

## Anti-patterns that fail candidates

- Jumping to the architecture before requirements
- Spending 15 minutes on estimation
- Picking technologies before understanding access patterns
- "We'll just use microservices" with no reason
- Ignoring failure ("assume the DB is always up")
- Hand-waving the hard part ("we'll use a distributed lock" and not explaining how it works or fails)
- Designing for Google scale when the requirement is 1,000 QPS
- Never mentioning consistency, idempotency, or monitoring
