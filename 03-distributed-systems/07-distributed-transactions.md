# Distributed Transactions: 2PC, 3PC, Sagas, and the Outbox

**The problem:** one logical operation must update data in multiple places (shards, databases, services) atomically: all or nothing.

## Two-Phase Commit (2PC)

```
Coordinator                Participant A        Participant B
    |---- PREPARE ------------->|                    |
    |---- PREPARE -------------------------------->  |
    |<--- YES (voted, locked) --|                    |
    |<--- YES ------------------------------------- |
    | (writes COMMIT to its log — the point of no return)
    |---- COMMIT -------------->|                    |
    |---- COMMIT ---------------------------------> |
```

**Phase 1 (Prepare / Vote):** each participant durably writes its changes and locks resources, then votes YES (a promise that it *can* commit) or NO.
**Phase 2 (Commit / Abort):** if all voted YES, the coordinator logs the decision and tells everyone to commit; otherwise it aborts.

### The fatal flaw: blocking
If the coordinator crashes **after participants vote YES but before sending the decision**, participants are **in doubt**. They can't commit (maybe someone voted NO) and can't abort (maybe the coordinator decided commit). They hold locks **until the coordinator recovers**.

### Other costs

- Latency: 2 round trips plus forced log writes (fsyncs)
- Locks held across the network round trips, which reduces throughput under contention
- Coordinator is a SPOF (mitigate: replicate the coordinator log with consensus)
- All participants must support XA or prepare (many systems don't: Kafka, most NoSQL, third-party APIs)

### Where 2PC works well

- **Inside a distributed database** where participants are Paxos/Raft groups (the "participant" never fails permanently because it's itself replicated). **Spanner, CockroachDB, YugabyteDB** do 2PC across shards on top of consensus, which removes the blocking problem in practice.
- XA transactions across homogeneous databases (rarely recommended; operationally painful).

## Three-Phase Commit (3PC)

Adds a "pre-commit" phase so participants can decide on coordinator failure. **Assumes bounded network delay** and isn't safe under partitions. Rarely used in practice. Know it exists and why it isn't used.

## Sagas (Garcia-Molina & Salem, 1987)

A sequence of **local transactions**, each with a **compensating transaction** that semantically undoes it.

```
T1: Create order (PENDING)          C1: Cancel order
T2: Reserve inventory               C2: Release inventory
T3: Charge payment                  C3: Refund payment
T4: Confirm order (CONFIRMED)

If T3 fails → run C2, C1
```

### Choreography vs orchestration

| | Choreography | Orchestration |
|---|---|---|
| How | Each service emits events; others react | A central orchestrator tells each service what to do |
| Coupling | Loose, implicit | Explicit flow in one place |
| Visibility | Hard to see the overall flow | Easy to monitor and debug |
| Complexity growth | Event spaghetti with many steps | Manageable |
| Tools | Kafka/events | Temporal, AWS Step Functions, Cadence, Camunda, Netflix Conductor |
| Use when | 2–4 steps, simple | Complex flows, many steps, timeouts, human steps |

**Senior recommendation:** orchestration with a **durable workflow engine** (Temporal) for anything non-trivial. It persists state, handles retries and timeouts, and makes compensation explicit.

### Saga pitfalls (interviewers love these)

1. **No isolation.** Intermediate states are visible: other transactions can see "inventory reserved but payment not yet charged." Countermeasures:
    - **Semantic locks:** mark records as PENDING; other operations treat PENDING specially
    - **Commutative updates** where possible
    - **Pessimistic view:** reorder steps so risky steps come last
    - **Re-read values** before acting (version check)
2. **Compensations must be idempotent and retryable.** They can be delivered more than once.
3. **Compensations can fail.** Retry forever (with alerts), or escalate to manual intervention.
4. **Some actions can't be compensated** (a sent email, a shipped package). Put them **last** (the "pivot transaction": steps before it are compensatable, steps after it are retriable until success).
5. **Compensation isn't rollback.** A refund is a new transaction and leaves a trace (good for audit).

### Step types

- **Compensatable** (before the pivot): can be undone
- **Pivot:** the go/no-go point (e.g., charging the card)
- **Retriable** (after the pivot): must eventually succeed, so retry until done

## Transactional Outbox (the most important pattern here)

**Problem (dual write):** update the DB **and** publish an event. Either can fail independently.

**Solution:**
```
BEGIN;
  UPDATE orders SET status='PAID' WHERE id=42;
  INSERT INTO outbox(id, topic, key, payload, created_at) VALUES (...);
COMMIT;

Relay process: read outbox → publish to Kafka → mark sent (or delete)
```

**Relay options:**

- **Polling publisher:** `SELECT ... FROM outbox WHERE sent=false ORDER BY id LIMIT 100 FOR UPDATE SKIP LOCKED`. Simple; adds DB load and some latency.
- **CDC (log tailing):** Debezium reads the WAL/binlog and publishes outbox inserts. Low latency, no polling, preserves commit order. **Preferred at scale.**

**Guarantees:** at-least-once publishing (the relay may crash after publishing, before marking sent), so **consumers must be idempotent** (dedup by event ID).

**Ordering:** publish with the aggregate ID as the Kafka key, so per-aggregate order is preserved.

### Related patterns

- **Inbox:** consumer stores processed message IDs in the same transaction as its state change, for dedup.
- **Listen to yourself:** a service writes only an event, then consumes its own event to update its DB (event sourcing-ish).
- **CDC as an integration backbone:** stream DB changes to search indexes, caches, and analytics (avoids dual writes to Elasticsearch).

## Other approaches

### TCC (Try-Confirm-Cancel)

- **Try:** reserve resources (e.g., hold $50 in a "frozen" balance)
- **Confirm:** finalize the reservation
- **Cancel:** release it
- Like 2PC at the business level, without DB-level locks. Common in Chinese fintech (Alibaba Seata). The reservation has a timeout.

### Reservation pattern
Generalization of TCC: hold the resource with an expiry, confirm or let it expire. (Seat holds, inventory holds, payment authorizations: an auth is a reservation and capture is the confirmation.)

### Avoid distributed transactions entirely

- **Redesign boundaries:** put the data that must change atomically in one service/DB. If two services always need atomic updates together, they may be one service.
- **Co-locate by partition key:** the order and its line items share `order_id`, so it's a single-shard transaction.
- **Accept eventual consistency** with reconciliation jobs that detect and fix drift.
- **Use a distributed SQL DB** that handles it for you (Spanner, CockroachDB), at a latency cost.

## Decision guide

| Situation | Approach |
|---|---|
| Multiple rows in one DB | Local ACID transaction |
| Multiple shards of a distributed SQL DB | The DB's built-in transactions (2PC over Raft/Paxos) |
| DB write + event publish | **Transactional outbox** |
| Multi-service business process (order → inventory → payment → shipping) | **Saga (orchestrated)** with idempotent steps and compensations |
| Resource reservation with user think time | Reservation/TCC with TTL |
| Cross-service invariant that must never be violated | Re-think service boundaries; or a single source of truth with a synchronous check |
| External third-party systems | Saga + idempotency keys + reconciliation |

## Interview sound bite

> "I won't use 2PC across services. It blocks on coordinator failure and our services don't support prepare. Instead, each service commits locally and emits events through a transactional outbox, with an orchestrated saga in Temporal driving order → inventory hold → payment → confirm. Payment is the pivot: inventory hold is compensatable, and confirmation and shipping are retriable. Every step takes an idempotency key derived from the order ID, and a nightly reconciliation job compares orders, payments, and inventory to catch anything that slipped through."
