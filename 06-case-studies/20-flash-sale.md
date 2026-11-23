# Case Study 20: Flash Sale / Inventory at Extreme Contention (Amazon Lightning Deals, Alibaba Singles' Day)

> Tests: extreme write contention on a handful of keys, preventing oversell, admission control with queues, async order processing, and protecting the rest of the system.

## 1. Requirements

**Functional**

- Limited inventory (e.g., 10,000 units) of an item at a discounted price, starting at a fixed time
- Users click "buy"; first come, first served until sold out
- Limit per user (1 unit)
- Successful buyers complete checkout/payment within N minutes or the unit is released

**Non-functional**

- **Peak: 1M+ requests/s** at the sale start, for a few seconds, mostly for one or a few SKUs
- **Never oversell**; underselling (a few unsold units briefly) is OK
- The rest of the site must stay up
- Fair (roughly arrival order), with bot resistance

## 2. The core problem

10K units, 1M concurrent buyers, one inventory counter. Any design that sends 1M writes/s to one DB row fails. **Most requests must be rejected cheaply and early**, because 99% of them will lose anyway.

## 3. Layered funnel design

```
1M req/s
  → CDN: static product page, countdown, JS (no origin hits)
  → Edge/gateway: rate limit per user/IP, bot detection, require a pre-issued sale token; drop excess
  → "Sold out?" flag cached locally (in-process, pushed) → instant rejection once sold out
100K req/s
  → Inventory reservation layer (Redis atomic decrement / in-memory allocator)
10K successes
  → Order queue (Kafka) → Order service creates orders asynchronously → Payment (with hold timeout)
```

## 4. Deep dive: atomic inventory decrement

**Redis Lua script (atomic, single-threaded):**
```lua
-- KEYS[1]=stock:{sku}, KEYS[2]=buyers:{sku}; ARGV[1]=user_id
if redis.call('SISMEMBER', KEYS[2], ARGV[1]) == 1 then return -2 end   -- already bought (per-user limit)
local stock = tonumber(redis.call('GET', KEYS[1]))
if stock <= 0 then return -1 end                                       -- sold out
redis.call('DECR', KEYS[1])
redis.call('SADD', KEYS[2], ARGV[1])
return 1
```

- Hash tags (`{sku}`) keep both keys on the same shard.
- ~100K+ ops/s on one Redis shard. If that's not enough: **split the stock across N shards** (`stock:{sku}:0..N-1`, each with 10K/N units). Route a user to `hash(user) % N`; on "sold out" in their shard, optionally try another (or accept slight underselling until rebalance).

**Durability concern:** Redis async replication means a failover could lose decrements, which risks **oversell**. Mitigations:

- The DB is the final arbiter: the order service does `UPDATE inventory SET sold = sold + 1 WHERE sku=? AND sold < total` (or claims a pre-generated unit row) before confirming. A Redis "win" that fails at the DB gets an apology/refund (rare).
- Or use Redis with `WAIT` / MemoryDB / a Raft-backed in-memory store for the counter.

**Alternative: pre-generated tokens.** Create 10K "unit" rows or tokens upfront; buyers claim one with `SKIP LOCKED` or `SPOP` from a Redis set of unit IDs. Each unit is claimed by exactly one buyer, with no counter contention.

**Alternative: single-writer queue.** Put all buy requests for the SKU into one Kafka partition; one consumer allocates sequentially in memory (millions/s), giving strict first-come-first-served fairness. Users get an async result ("you're in line… success!"). Alibaba-style designs combine queues with local in-memory stock.

## 5. Deep dive: async order creation

- A winning reservation produces an **order request message** (with a reservation ID as the idempotency key) to Kafka.
- The order service consumes at a sustainable rate, creates the order (idempotent on reservation ID), and starts the payment window.
- The user's UI polls or receives a push: "Order confirmed, pay within 10 minutes."
- **Payment timeout:** a delayed message/timer releases the unit (`INCR stock` + remove the user from the buyers set, conditionally if not paid). Released units can go back on sale or to a waitlist.

## 6. Protecting the rest of the system

- **Isolate** the flash sale: a separate cluster/cell for the sale SKU's inventory and order intake, so the main catalog/checkout isn't affected.
- Rate limits and load shedding at the edge; **feature degradation** (turn off recommendations and reviews on the sale page).
- Pre-scale everything; warm caches; run load tests at 2–3× the expected peak.

## 7. Fairness and bots

- Pre-registration + a **sale token** issued before start; a random lottery in the queue position (fairer than milliseconds of network latency).
- CAPTCHA/proof-of-work at entry; per-account and per-payment-method limits; device fingerprinting.

## 8. Failure modes

| Failure | Handling |
|---|---|
| Redis shard failover mid-sale | DB final check prevents oversell; pause the sale briefly if needed |
| Order service lagging | Kafka buffers; users see "processing"; reservations hold the stock meanwhile |
| User wins but payment fails/times out | Release the unit (idempotent), offer it to the waitlist |
| Thundering herd at T=0 | CDN static page with a client-side countdown + randomized jitter on the button enable; queue tokens |
| Duplicate clicks | Per-user set check in the Lua script + idempotent reservation ID |

## 9. Sound bite

> "Ninety-nine percent of requests must lose, so the design is about rejecting them as cheaply and as early as possible: CDN, then edge rate limits, then a local sold-out flag, then an atomic Redis decrement, and only winners reach the order queue. The DB conditional update is the final guard against oversell if Redis loses writes on failover. Orders are created asynchronously, so the database sees 10K writes, not 1M."
