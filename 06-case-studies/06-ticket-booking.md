# Case Study 06: Ticket Booking (Ticketmaster / BookMyShow / Airline Seats)

> **The quintessential concurrency interview.** Tests: preventing double-booking under extreme contention, holds with expiry, handling a flash crowd (Taylor Swift tickets), and payment integration.

## 1. Requirements

**Functional**

- Browse events and view the seat map with availability
- Select specific seats (reserved seating) or quantity (general admission)
- **Hold** seats for ~10 minutes while the user pays
- Confirm the booking on successful payment; release on timeout or failure

**Non-functional**

- **Never double-book a seat** (strong consistency for seat state)
- Handle flash crowds: **millions of users** hitting one event at on-sale time
- Seat map can be slightly stale (seconds), but booking must be correct
- Fairness (first come, first served, roughly), bot protection
- Availability: browse highly available; booking can degrade to a queue

## 2. Estimation (on-sale of a mega event)

- 50K seats; 10M users trying in the first minutes.
- Normal: ~100s of bookings/s globally. **Peak for one event: 100K–1M requests/s**, all contending for the same 50K rows.
- The bottleneck isn't storage; it's **contention on a small hot dataset**.

## 3. Data model

```
events(event_id, venue_id, start_time, on_sale_at, ...)
seats(event_id, seat_id, section, row, price_tier,
      status ENUM(AVAILABLE, HELD, BOOKED),
      hold_id, held_until, booking_id, version)
      PRIMARY KEY (event_id, seat_id)
holds(hold_id, user_id, event_id, seat_ids[], expires_at, status)
bookings(booking_id, user_id, event_id, seat_ids[], payment_id, status, idempotency_key UNIQUE)
```

## 4. The core problem: two users, one seat

```
User A: SELECT status FROM seats WHERE id=A12 → AVAILABLE
User B: SELECT status FROM seats WHERE id=A12 → AVAILABLE
User A: UPDATE seats SET status=HELD ...
User B: UPDATE seats SET status=HELD ...    ← double hold → double booking
```

### Solution options

**Option 1: Pessimistic row lock**
```sql
BEGIN;
SELECT * FROM seats WHERE event_id=? AND seat_id IN (...) ORDER BY seat_id FOR UPDATE;
-- verify all AVAILABLE (or HELD with expired held_until)
UPDATE seats SET status='HELD', hold_id=?, held_until=now()+interval '10 min' WHERE ...;
COMMIT;
```

- ✅ Correct; handles multi-seat atomically. `ORDER BY seat_id` avoids deadlocks.
- ❌ Blocking under heavy contention; lock waits pile up.
- Use `NOWAIT` / `SKIP LOCKED` to fail fast: "seat just got taken."

**Option 2: Atomic conditional update (optimistic, preferred)**
```sql
UPDATE seats
SET status='HELD', hold_id=:hold, held_until=now()+interval '10 min', version=version+1
WHERE event_id=:e AND seat_id IN (:s1,:s2)
  AND (status='AVAILABLE' OR (status='HELD' AND held_until < now()));
-- rows_affected must equal number of seats requested; else rollback (partial = fail)
```

- ✅ Single statement, no explicit locks held across round trips; the DB serializes per row.
- ✅ Expired holds are reclaimed lazily inside the same condition.
- For multiple seats, wrap in a transaction and roll back if `rows_affected < n`.

**Option 3: Redis atomic hold** (for extreme throughput)
```
SET seat:{event}:{seat} hold_id NX EX 600      # one seat
-- multi-seat: Lua script checks all keys free, then sets all (atomic)
```

- ✅ ~100K+ ops/s per shard; TTL gives automatic expiry.
- ❌ Redis isn't the system of record (async replication → failover could lose holds → potential double hold). Mitigate: **the DB confirms at booking time** with a conditional update (Redis = fast admission filter, DB = final arbiter), or use a stronger store.

**Option 4: Unique constraint as the arbiter**
```sql
INSERT INTO seat_claims(event_id, seat_id, hold_id, expires_at) VALUES (...);
-- UNIQUE(event_id, seat_id): second insert fails
```

- Expired claims need cleanup before a re-claim (delete expired rows first, or use a conditional upsert).

**Option 5: Single writer per event (actor / partition)** for the mega on-sale

- Route every hold request for event E to **one partition/actor** owning E's seat map **in memory**, processing requests sequentially (thousands to millions per second in memory), persisting decisions to the DB/log.
- ✅ No lock contention at all; deterministic; fair ordering.
- ❌ Need failover for the actor (leader election, state rebuilt from the log); a single event is bounded by one core, which is still plenty for 50K seats.

**Recommendation to state:** "Conditional updates in the DB as the source of truth. For mega on-sales, add a virtual waiting room in front, plus Redis or an in-memory per-event allocator to absorb the burst, with the DB conditional update as the final guard."

## 5. Hold → pay → confirm flow (with failure handling)

```
1. POST /holds {event, seats, idempotency_key}
     → atomic hold (status=HELD, held_until=now+10m) → return hold_id, expires_at
2. Client goes to payment (Stripe etc.) with idempotency key = hold_id
3. Payment success webhook/callback →
     BEGIN;
       UPDATE seats SET status='BOOKED', booking_id=:b
       WHERE hold_id=:hold AND status='HELD' AND held_until > now();   -- must match all seats
       INSERT INTO bookings(...);   (+ outbox event BookingConfirmed)
     COMMIT;
4. If step 3 affects 0 rows (hold expired and seat re-sold!) → REFUND payment (compensation)
5. Expiry: lazy (condition in step 1) + sweeper job releasing expired holds to update the seat map
```

**Critical edge case: payment succeeds after the hold expired.**

- Option A: extend holds slightly beyond the payment provider's timeout; once payment starts, mark the hold `PAYMENT_PENDING` (not expirable) with a hard cap.
- Option B: if confirmation fails, refund automatically (saga compensation) and apologize.
- Use **authorize → confirm seats → capture** (an authorization is a reservation of funds). If seat confirmation fails, void the authorization (no refund needed).

**Idempotency:** a payment webhook can arrive twice, so the confirm step must be idempotent (`WHERE status='HELD'` already makes the second call a no-op; check `booking_id` to return the same result).

## 6. Deep dive: the flash crowd (virtual waiting room)

You can't let 10M users hit the booking service at once.

```
Users → CDN → Waiting Room service → (admitted at controlled rate) → Booking flow
```

- At on-sale, users get a **queue position** (random or arrival order, with token-based fairness).
- The waiting room admits N users/minute based on downstream capacity (seats left, booking throughput).
- Admitted users get a **signed, time-limited access token** (JWT) required by the booking APIs, so bots can't skip the queue.
- The waiting room is mostly static (served from the CDN), with a lightweight position-polling endpoint (heavily cached, e.g., Redis sorted set rank or a counter comparison: "your number vs. now serving").
- **Benefits:** turns an uncontrolled spike into a controlled flow; fairness; bot mitigation (CAPTCHA at entry, verified fan pre-registration).
- Ticketmaster's "Smart Queue" and Queue-it work this way.

## 7. Deep dive: seat map reads at scale

- Millions of users polling the seat map is far heavier than booking.
- Serve availability from a **cache** (Redis bitmap per event/section: 1 bit per seat; 50K seats = 6 KB), updated on every hold/release/book via events.
- Push updates over WebSocket/SSE to viewers (or poll every 2–5s with CDN micro-caching of 1s).
- **Seat map may be stale.** That's fine, because the hold operation is the authoritative check. The UI handles "seat just taken" gracefully and suggests alternatives.
- **Best-available selection** (the server picks seats) reduces contention dramatically versus users fighting over the same front-row seats.

## 8. General admission (quantity-based)

No specific seats: inventory is a count.

- `UPDATE inventory SET available = available - :n WHERE event_id=? AND tier=? AND available >= :n`
- Hot row! For a huge GA event, **split inventory into N buckets** (rows), pick a random bucket, decrement; on failure try others. Or **pre-generate ticket tokens** and claim with `SKIP LOCKED`:
    ```sql
    UPDATE tickets SET hold_id=:h, held_until=...
    WHERE id IN (SELECT id FROM tickets WHERE event_id=? AND status='AVAILABLE'
                 LIMIT :n FOR UPDATE SKIP LOCKED)
    ```
    Concurrent buyers grab **different** rows, so there's no contention. This is an excellent pattern to mention.

## 9. Architecture

```
Client → CDN (static, waiting room) → API Gateway (rate limit, bot detection, access token check)
   ├── Event/Catalog Service (read-heavy, cached, Elasticsearch for search)
   ├── Seat Map Service (Redis bitmaps + WebSocket push)
   ├── Booking Service ──> Seats DB (Postgres/Spanner, partitioned by event_id)
   │       │                   └── outbox → Kafka (SeatHeld, SeatReleased, BookingConfirmed)
   │       └── Hold Expiry worker (sweeper) / delayed messages
   ├── Payment Service (idempotent, PSP integration, webhooks)
   └── Notification Service (email tickets, consumes BookingConfirmed)
```

- **Partition the seats DB by event_id.** All seats of an event on one shard means multi-seat holds are single-shard transactions.

## 10. Failure modes

| Failure | Handling |
|---|---|
| User abandons | Hold expires (lazy + sweeper) |
| Booking service crash mid-hold | Transaction rolls back or the hold expires |
| Payment succeeded, confirm failed (crash) | Payment webhook retry → idempotent confirm; reconciliation job matches payments ↔ bookings; refund if the seat was lost |
| Double click / retry on "Book" | Idempotency key on hold and booking |
| Redis (hold cache) failover loses holds | DB conditional update is the final guard; worst case the user sees "seat unavailable" at confirm |
| DB shard for a mega event overloaded | Waiting room throttles admission; in-memory per-event allocator |
| Bots | Waiting room + CAPTCHA + access tokens + per-account purchase limits |

## 11. Follow-ups

- **Why not a distributed lock per seat?** You could (Redis `SET NX` per seat), but the conditional update in the DB is simpler, atomic with the state change, and needs no separate lock lifecycle. Locks add a failure mode (holder dies) and still need fencing.
- **Multi-region:** an event is homed to one region (its seats DB). Users globally route booking calls to that region. Browsing is served locally from replicas/cache.
- **Seat "hold" vs "lock" naming:** a hold is business state with an expiry, persisted, and visible. It isn't a technical lock.
- **Overbooking (airlines):** deliberately sell above capacity based on a no-show prediction; the inventory count allows `available >= -overbook_limit`.
