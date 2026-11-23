# Idempotency and Exactly-Once Semantics

## Why this matters more than almost anything else

In a distributed system, **a timeout tells you nothing**. The request might have:
1. Never arrived
2. Arrived and failed
3. Arrived, **succeeded**, and the response was lost

The only safe way to retry is to make the operation **idempotent**: applying it N times has the same effect as applying it once.

## Delivery semantics

| Semantics | How | Risk |
|---|---|---|
| **At-most-once** | Send once, never retry | Lost messages |
| **At-least-once** | Retry until acked | Duplicates |
| **Exactly-once** | — | **Impossible for delivery** in the general case (Two Generals problem) |

**What people actually mean by "exactly-once":** **exactly-once processing (effect)** = at-least-once delivery + idempotent processing (or dedup). Kafka's exactly-once is this within the Kafka ecosystem (idempotent producers + transactions + read_committed consumers).

> Interview: "Exactly-once delivery isn't possible, but we get exactly-once *effects* with at-least-once delivery and idempotent consumers."

## Naturally idempotent operations

- `SET x = 5` ✅ vs `x = x + 1` ❌
- `PUT /users/1 {full object}` ✅
- `DELETE /orders/1` ✅ (the second delete is a no-op or 404)
- "Mark order 123 as shipped" ✅ vs "Ship an order" ❌
- Upsert by natural key ✅

**Design tip:** turn deltas into absolute states, or attach a unique ID to deltas.

## Idempotency keys (the standard pattern)

The client generates a unique key (UUID) per **logical operation** and reuses it on every retry.

```
POST /v1/charges
Idempotency-Key: a1b2c3...
{ amount: 5000, currency: "usd", customer: "cus_1" }
```

### Server-side algorithm (Stripe-style)

```
idempotency_keys table:
  key (PK, scoped per client/account)
  request_hash
  status: IN_PROGRESS | COMPLETED | FAILED_RETRYABLE
  response_code, response_body
  locked_at, created_at (TTL ~24h)
  recovery_point (for multi-step operations)
```

```python
def handle(req, key):
    # 1. Atomically claim the key. INSERT relies on the unique constraint.
    try:
        insert(key, hash(req), status=IN_PROGRESS, locked_at=now())
    except UniqueViolation:
        row = get(key)
        if row.request_hash != hash(req):
            return 422  # same key, different request: client bug
        if row.status == COMPLETED:
            return row.response  # replay the stored response
        if row.status == IN_PROGRESS and not stale(row.locked_at):
            return 409  # concurrent duplicate in flight, retry later
        # stale IN_PROGRESS (crashed worker) → resume from recovery_point

    # 2. Do the work. Ideally in the SAME DB transaction as the key update.
    result = process(req)

    # 3. Store the response
    update(key, status=COMPLETED, response=result)
    return result
```

**Critical details:**
- **Atomic claim:** use a unique constraint or conditional insert, never "check, then insert."
- **Same transaction:** if the business write and the idempotency record are in the same DB, commit them together. Then a crash can't leave one without the other.
- **External side effects** (calling a payment processor) can't share the DB transaction. Pass **your own idempotency key downstream** (Stripe → card network, your service → Stripe), and record **recovery points** for multi-step flows.
- **Scope keys** per client or account so one client can't collide with another.
- **TTL:** keep keys long enough to cover the client's retry window (24h is common).
- **Store the response**, including errors that are deterministic (e.g., a card decline). Don't store transient 5xx errors as final.

## Idempotent consumers (message processing)

At-least-once queues **will** deliver duplicates (consumer crashed after processing but before committing the offset or ack, visibility timeout expired, producer retries).

### Strategy 1: dedup table in the same transaction
```sql
BEGIN;
INSERT INTO processed_messages(message_id) VALUES (:id);  -- unique PK; fails on duplicate
UPDATE accounts SET balance = balance + :amt WHERE id = :acct;
COMMIT;
```
If the insert fails with a unique violation, it's a duplicate, so skip it and ack.

### Strategy 2: natural idempotency via conditional writes
```sql
UPDATE orders SET status='PAID', payment_id=:pid
WHERE id=:oid AND status='PENDING';
```
A replay is a no-op.

### Strategy 3: version/sequence check
Store `last_processed_seq` per entity and ignore events with `seq <= last_processed_seq`. Works well with per-key ordered streams (Kafka partition by entity ID).

### Strategy 4: store offsets with the data
Consumer writes results and the Kafka offset in the **same DB transaction**. On restart, seek to the stored offset. That gives exactly-once effect into that DB.

## Kafka exactly-once (EOS)

- **Idempotent producer** (`enable.idempotence=true`): the broker dedupes by (producer ID, partition, sequence number). This fixes duplicates from producer retries.
- **Transactions:** atomically write to multiple partitions **and** commit consumer offsets (`sendOffsetsToTransaction`). Consumers with `isolation.level=read_committed` only see committed data.
- This gives exactly-once for **consume → process → produce within Kafka**. For external sinks you still need idempotent writes or transactional sinks.

## The dual-write problem (and the outbox)

```python
db.save(order)          # succeeds
kafka.publish(event)    # fails or crashes → DB and event stream diverge
```
Reversing the order doesn't help either. You can't atomically write to two systems without a distributed transaction.

**Fix: Transactional Outbox**
1. In the same DB transaction, write the business row **and** an `outbox` row.
2. A relay (poller or CDC like Debezium reading the WAL) publishes outbox rows to Kafka, **at least once**.
3. Consumers are idempotent (dedup by event ID).

```sql
BEGIN;
INSERT INTO orders (...) VALUES (...);
INSERT INTO outbox (id, aggregate_id, type, payload) VALUES (uuid, :order_id, 'OrderCreated', :json);
COMMIT;
```

**Inbox pattern** on the consumer side: store received message IDs (dedup) in the same transaction as the processing.

See [03-distributed-systems/07-distributed-transactions.md](../03-distributed-systems/07-distributed-transactions.md).

## Retries done right

1. **Only retry idempotent operations** (or ones with idempotency keys).
2. **Exponential backoff with jitter:** `sleep = random(0, min(cap, base * 2^attempt))` ("full jitter," from the AWS architecture blog).
3. **Retry budgets:** cap retries at around 10% of requests so retries can't multiply load during an outage.
4. **Retry at one layer only.** If every one of 5 layers retries 3 times, the bottom layer sees 3^5 = 243× the load. Retry at the edge or a designated layer.
5. **Respect `Retry-After`** and circuit breakers.
6. **Deadlines:** don't retry if the caller's deadline has passed.

## Common interview scenarios

| Scenario | Idempotency approach |
|---|---|
| Payment API | Client idempotency key + stored response + downstream idempotency key to PSP |
| Order creation from a mobile app on a flaky network | Client-generated order ID (UUID) as PK; retry is an upsert |
| Kafka consumer updating balances | Dedup table keyed by event ID in the same transaction |
| Sending emails/push | Dedup key (user, notification_id) in Redis/DB with TTL; accept rare duplicates or check before sending |
| Webhook receiver | Dedup by event ID |
| Inventory decrement | Reservation ID: `INSERT reservation(id, sku, qty)` with unique ID; stock derived from reservations, or conditional decrement keyed by reservation |
| File upload | Content hash as ID (content-addressed) |
