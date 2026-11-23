# Event-Driven Architecture, CQRS, and Event Sourcing

## Events vs commands vs queries

| | Meaning | Example | Coupling |
|---|---|---|---|
| **Command** | "Do this" (directed at one handler; can be rejected) | `ReserveSeat` | Sender knows the receiver |
| **Event** | "This happened" (a fact, past tense, immutable) | `SeatReserved` | Publisher doesn't know subscribers |
| **Query** | "Tell me" | `GetSeatMap` | Request/response |

## Event types

- **Event notification:** thin ("Order 42 changed"); consumers call back for details. Low coupling on schema, more chatty, and the callback may see newer state.
- **Event-carried state transfer:** fat (includes the data); consumers keep local copies. No callbacks; consumers see eventual consistency; larger events.
- **Domain events** (business facts) vs **CDC events** (row changes). Domain events are a better public contract; CDC leaks internal schema.

## Benefits and costs

✅ Loose coupling, independent scaling, extensibility (new consumers without touching the producer), audit trail, temporal decoupling (consumers can be down).
❌ Eventual consistency, debugging flows across services, schema evolution, duplicate/out-of-order handling, "where did my event go?" moments.

## Schema evolution

- Use a **schema registry** (Confluent, AWS Glue) with Avro/Protobuf.
- **Backward compatible** changes only: add optional fields with defaults, never remove or rename required fields, never reuse field numbers.
- Version event types (`OrderCreated.v2`) for breaking changes; run both during migration.

## CQRS (Command Query Responsibility Segregation)

Separate the **write model** (commands, validation, invariants) from the **read model(s)** (denormalized, query-optimized views).

```
Commands → Write model (normalized DB / event store)
              ↓ events / CDC
          Projectors → Read models (Elasticsearch, Redis, denormalized tables, OLAP)
Queries → Read models
```

- ✅ Each side scales and is optimized independently; multiple read models for different needs (search, dashboards, feed).
- ❌ **Read models lag** (eventual consistency); more moving parts.
- **Handling lag in the UI:** return the new version from the command, and have the client poll or wait until the read model reaches that version; optimistic UI.
- **When to use:** read and write patterns differ significantly, or there are complex domains with many query shapes. **Not for simple CRUD.**

## Event sourcing

**Store state as a sequence of events** rather than current values. Current state = fold(events).

```
Account 42:
  AccountOpened(42, owner=alice)
  Deposited(42, 100)
  Withdrawn(42, 30)
  Deposited(42, 50)
→ balance = 120
```

### Mechanics
- **Event store:** append-only, per-aggregate stream with **optimistic concurrency**: `append(stream=account-42, expected_version=3, events=[...])` fails if the version ≠ 3. That's how concurrent commands on one aggregate are serialized.
- **Snapshots:** periodically store the state at version N to avoid replaying thousands of events.
- **Projections:** build read models from events (CQRS read side).
- **Replay:** rebuild projections from scratch, or create new ones from history.

### Benefits
- Complete **audit log** (finance, compliance)
- **Time travel:** state at any point in the past
- Debugging: reproduce bugs by replaying events
- New read models from historical data

### Costs and pitfalls
- **Schema evolution of events is forever.** Old events must remain readable (upcasters).
- **GDPR "right to be forgotten"** conflicts with immutability. Use crypto-shredding (encrypt PII per user and delete the key).
- Querying current state needs projections.
- Eventual consistency of projections.
- Steep learning curve; easy to over-apply. **Use it for the core domain where audit and history matter (ledgers, orders), not everywhere.**

### Event sourcing vs. a transaction log
Databases already do this internally (the WAL is an event log; tables are a cached projection). Kafka + compacted topics + stream processing = "turning the database inside out" (Kleppmann).

## Choreography vs orchestration (again)

See [03-distributed-systems/07-distributed-transactions.md](../03-distributed-systems/07-distributed-transactions.md). Choreography for simple reactive flows; orchestration (Temporal, Step Functions) for multi-step business processes.

## Ordering and consistency in event-driven systems

- Partition events by **aggregate ID** to preserve per-entity order.
- Include **version/sequence numbers** in events; consumers detect gaps and duplicates.
- **Idempotent consumers** (inbox/dedup table).
- Out-of-order across aggregates is normal. Don't build logic that depends on global order.

## Event-driven anti-patterns

- **Event as remote procedure call:** "PleaseSendEmailEvent" with only one consumer. That's a command; use a queue.
- **Giant shared event schema** coupling every team.
- **Synchronous chains disguised as events** (service A waits for an event reply from B).
- **No dead-letter handling**, so poison messages block partitions.
- **Missing correlation IDs**, so flows can't be traced.
