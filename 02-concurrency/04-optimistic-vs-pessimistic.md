# Optimistic vs Pessimistic Concurrency Control

## The core idea

- **Pessimistic:** "Conflicts are likely, so lock first and then work." Blocks others.
- **Optimistic:** "Conflicts are rare, so work first and check at the end." Retries on conflict.

## Comparison

| | Pessimistic | Optimistic |
|---|---|---|
| Mechanism | Locks (`SELECT FOR UPDATE`, mutex, distributed lock) | Version/timestamp check at write (CAS, ETag, `WHERE version=?`) |
| Low contention | Wasted lock overhead | ✅ Excellent, almost no overhead |
| High contention | ✅ Predictable, queues requests | ❌ Retry storms, wasted work, possible livelock |
| Deadlocks | Possible | Impossible (no locks held) |
| Long operations / user think time | ❌ Can't hold a DB lock while a user fills in a form | ✅ Natural fit (ETag on edit forms) |
| Across services / network | Hard (distributed locks, leases) | ✅ Easy (conditional writes) |
| Failure of holder | Lock must be released (timeouts, leases) | Nothing to release |

## Rule of thumb

- **Conflict rate < ~10%:** optimistic.
- **Conflict rate high and the work is cheap to queue:** pessimistic, or better, a **single writer**.
- **Extreme contention** (a flash sale on one SKU, 100K users per second on one seat map): neither works well directly. **Restructure:** queue, shard, pre-allocate, or batch.

## Optimistic patterns

### Version column
```sql
-- read
SELECT id, balance, version FROM accounts WHERE id = 1;  -- version = 7
-- write
UPDATE accounts SET balance = 150, version = 8
WHERE id = 1 AND version = 7;
-- rows_affected == 0 → someone else won → reload and retry (or report a conflict to the user)
```

### HTTP ETag / If-Match
```
GET /docs/1           → ETag: "7"
PUT /docs/1 If-Match: "7"   → 412 if changed
```

### DynamoDB conditional writes
```
UpdateItem(Key={id:1}, UpdateExpression="SET qty = qty - :one",
           ConditionExpression="qty >= :one")
```

### etcd/ZooKeeper

- etcd: `Txn().If(Compare(ModRevision(key), "=", rev)).Then(Put(...))`
- ZooKeeper: `setData(path, data, expectedVersion)`

### Redis
```
WATCH stock:42
val = GET stock:42
MULTI
SET stock:42 (val-1)
EXEC   → nil if stock:42 changed since WATCH
```
Usually better: a Lua script, which runs atomically on the single thread.

## Pessimistic patterns

### DB row lock
```sql
BEGIN;
SELECT * FROM seats WHERE id = 'A12' FOR UPDATE;   -- others block here
-- check status == 'available'
UPDATE seats SET status='held', held_by=:user, hold_expires=now()+'10 min' WHERE id='A12';
COMMIT;
```
Keep the transaction **short**. Never hold a DB lock across a user interaction or an external API call.

### Distributed lock
See [05-distributed-locks.md](05-distributed-locks.md). Needed when the protected resource isn't in one transactional store.

## The hybrid that's usually correct: "reservation with expiry"

For anything involving user think time (checkout, booking):

1. **Short pessimistic or atomic step:** atomically flip the seat from `AVAILABLE` to `HELD(user, expires_at)`.
2. **User completes payment** (minutes), with no locks held.
3. **Confirm with an optimistic check:** `UPDATE seats SET status='BOOKED' WHERE id=? AND held_by=? AND status='HELD'`.
4. **Expiry:** a sweeper or lazy check releases expired holds.

This is the pattern behind Ticketmaster, airline seats, hotel rooms, and flash-sale inventory. See [06-case-studies/06-ticket-booking.md](../06-case-studies/06-ticket-booking.md).

## Avoiding retry storms with optimistic control

- Exponential backoff **with jitter**
- Cap retries, then fail and surface the conflict
- If retries are frequent, the contention is real. Switch strategies.
- Make the operation commutative if you can (an increment instead of read-then-write), so it doesn't conflict at all.

## Interview sound bite

> "For editing a document's metadata I'll use optimistic concurrency with a version column. Conflicts are rare and we can't hold locks during user think time. For decrementing stock on a popular item during a sale, conflicts are near-certain, so optimistic retries would thrash. I'll use an atomic conditional decrement, and if one row still can't keep up, I'll split the stock into N sub-buckets or serialize through a per-SKU queue."
