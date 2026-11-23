# What Senior and Staff Signals Look Like

Same question, different levels. Here's what separates them.

## Levels comparison

| Dimension | Mid-level (L4/E4) | Senior (L5/E5) | Staff (L6/E6+) |
|---|---|---|---|
| Requirements | Takes them as given | Clarifies and quantifies | Challenges them, finds the hidden requirement, scopes by business value |
| Design | Working boxes and arrows | Justified components and trade-offs | Multiple viable designs compared, with an evolution path |
| Depth | Knows what components do | Knows how they work internally | Knows how they fail, and how to operate them |
| Failure | Mentions replicas | Designs for partial failure, retries, idempotency | Failure domains, blast radius, graceful degradation, recovery |
| Concurrency | "Use a lock" | Picks optimistic vs pessimistic vs queue with reasons | Removes contention by design (partitioning, single writer, CRDTs) |
| Consistency | "Strongly consistent" or "eventual" | Per-operation consistency choice | Formal model (linearizable vs causal vs read-your-writes) with cost per choice |
| Operations | Not mentioned | Monitoring and alerts | SLOs, rollouts, migrations, backfills, on-call burden, cost |
| Communication | Answers questions | Drives the discussion | Drives it and adjusts to the interviewer, says what to spend time on and why |

## Phrases that signal seniority (only if you mean them)

- "What's the consistency requirement for **this specific operation**?"
- "Let's think about what happens when this call **times out**. We don't know if it succeeded."
- "This creates a **hot partition** for celebrity users. Let me handle that separately."
- "Retries here need an **idempotency key**, otherwise we risk double charging."
- "Instead of locking, we can make the **partition key** the seat ID so a single consumer owns it. That removes contention."
- "A distributed lock without a **fencing token** isn't safe under GC pauses."
- "I'd use the **transactional outbox** so the DB write and the event publish can't diverge."
- "At this scale the bottleneck moves from the DB to the **fan-out**."
- "This adds operational complexity. Is the team ready to run Kafka, or would SQS be enough?"
- "Let me define the **SLO** first: 99.9% of feed loads under 300ms. That tells us how much caching we need."
- "What's the **blast radius** if this component fails?"
- "We can **degrade gracefully**: if the recommendation service is down, show the chronological feed."

## Depth questions interviewers use to probe

Be ready for "how does that actually work?" on anything you mention:

| You say | They ask |
|---|---|
| "Use consistent hashing" | How do virtual nodes help? What happens when a node joins? |
| "Use a distributed lock" | What if the lock holder pauses for 30s due to GC? |
| "Use Kafka" | How is ordering guaranteed? What happens when a consumer crashes mid-batch? What's ISR? |
| "Cache it in Redis" | How do you invalidate? What about a thundering herd on a cache miss? |
| "Use a quorum" | What's sloppy quorum? Does R+W>N give linearizability? (No!) |
| "Use eventual consistency" | How long is "eventual"? How do you resolve conflicts? |
| "Shard by user ID" | How do you reshard? What about cross-shard queries? Hot users? |
| "Use 2PC" | What if the coordinator dies after prepare? |
| "Use Raft" | What happens during a network partition? How does a new leader know which entries are committed? |
| "Exactly-once delivery" | Is that actually possible? (Exactly-once *processing* via idempotency, yes. Delivery, no.) |

## The trade-off sentence template

> "I'll use **[choice]** because **[requirement it satisfies]**. The cost is **[downside]**, which is acceptable because **[reason]**. If **[condition changes]**, I'd switch to **[alternative]**."

Example:
> "I'll use fan-out on write for timelines because reads are 100x more frequent than writes and we need <200ms reads. The cost is write amplification and stale timelines for a few seconds, which is fine for a social feed. For users with more than 1M followers, fan-out becomes too expensive, so I'd switch those to fan-out on read and merge at read time."

## Behaviours that sink senior candidates

1. **Buzzword soup.** Mentioning Kafka, Kubernetes, Cassandra, and GraphQL without reasons.
2. **Ignoring the question's core.** For ticket booking, the core is contention. Spending 20 min on the search UI misses it.
3. **No numbers.** "It needs to scale" with no idea of the scale.
4. **Defensive when challenged.** Treat a challenge as information.
5. **Perfect-world designs.** Never discussing what happens when things fail.
6. **Over-engineering.** Multi-region active-active for an internal tool with 100 users.
