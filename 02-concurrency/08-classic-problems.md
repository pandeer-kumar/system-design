# Classic Concurrency Problems in System Design

Each one appears in real interviews. Know the problem, the naive bug, and 2–3 solutions with trade-offs.

---

## 1. Double booking / overselling

**Problem:** two users book the last seat or item at the same moment.

**Naive bug:**
```python
if inventory.get(sku) > 0:      # both see 1
    inventory.decrement(sku)    # both decrement → -1
```

**Solutions:**

| Approach | How | When |
|---|---|---|
| Atomic conditional update | `UPDATE stock SET qty=qty-1 WHERE sku=? AND qty>0` | Default for counts |
| Unique constraint | `INSERT booking(seat_id, show_id)` with UNIQUE(show_id, seat_id) | Discrete items (seats) |
| Row lock | `SELECT ... FOR UPDATE` then check and update | Complex validation logic |
| Hold with TTL | Atomic flip to HELD + expiry, confirm on payment | User think time |
| Single-writer queue | All requests for an event go to one partition/actor | Extreme contention |

---

## 2. Lost update on counters (likes, views)

**Problem:** read-modify-write on a counter loses increments.

**Solutions:**

- Atomic increment (`INCR`, `UPDATE x = x + 1`)
- **Hot counter:** shard into N sub-counters (`likes:post:1:shard:{0..N-1}`), increment a random shard, sum on read (and cache the sum)
- **Write-behind batching:** buffer increments in memory or Kafka, flush aggregated deltas every second
- **Approximate:** HyperLogLog for unique counts

See [06-case-studies/19-distributed-counter.md](../06-case-studies/19-distributed-counter.md).

---

## 3. Thundering herd / cache stampede

**Problem:** a hot cache key expires, and 10,000 requests miss at once and hit the DB together.

**Solutions:**

- **Request coalescing / single-flight:** only one request recomputes; others wait for its result (Go `singleflight`, a per-key promise).
- **Lock on recompute:** `SET lock:key NX PX 5000`. The winner recomputes; losers serve stale data or wait briefly.
- **Stale-while-revalidate:** serve the stale value and refresh in the background.
- **Probabilistic early expiration (XFetch):** each request refreshes early with a probability that rises as expiry approaches: `if now - delta*beta*ln(rand()) >= expiry: recompute`.
- **TTL jitter:** randomize TTLs so keys don't expire together.

The same pattern also appears as a **reconnect storm** (every client reconnects after an outage; fix with jittered backoff) and as **cold start after a deploy** (warm caches first).

---

## 4. Duplicate processing (at-least-once delivery)

**Problem:** the consumer processes a message, crashes before acking, and the message is redelivered.

**Solutions:** idempotent consumers (dedup table, conditional writes, sequence checks). See [06-idempotency.md](06-idempotency.md).

---

## 5. Ordering violations

**Problem:** "Update profile" and then "delete profile" are processed in reverse order by parallel workers.

**Solutions:**

- **Partition by entity key** so a single consumer per partition preserves order (Kafka, Kinesis, SQS FIFO message groups)
- **Version numbers / sequence numbers:** reject or reorder stale events (`if event.version <= current.version: skip`)
- **Last-writer-wins with logical timestamps** (careful: LWW with wall clocks loses data)

**Gotcha:** retries can break ordering even within a partition (message 1 fails, message 2 succeeds, then message 1 is retried). Kafka: `max.in.flight.requests.per.connection` ≤ 5 with idempotence keeps ordering. Consumers: process sequentially per key, or use a per-key retry queue that blocks later messages for that key.

---

## 6. Split brain

**Problem:** a network partition leads both sides to elect a leader, and both accept writes.

**Solutions:**

- **Quorum-based election** (majority required: with 5 nodes, a side needs 3; at most one side can have a majority)
- **Fencing tokens / epochs** reject the old leader's writes
- **STONITH** ("shoot the other node in the head"): forcibly power off the old primary before promoting
- Use an **odd number of nodes**, or a witness/tiebreaker node

---

## 7. Hot partition / hot key

**Problem:** a celebrity's posts, a viral video, or a flash-sale SKU sends a disproportionate share of traffic to one shard.

**Solutions:**

- **Read hot key:** replicate it to multiple cache nodes (key suffix `#1..#N`, random pick), local in-process caching, CDN
- **Write hot key:** split into sub-keys (sharded counters), batch writes, queue and serialize
- **Detect:** per-key metrics, top-K sketches (Count-Min Sketch) on the proxy
- **Partition-key design:** add salt (`user_id#bucket`) for write-heavy keys; DynamoDB adaptive capacity

---

## 8. Race between cache and DB (stale cache)

**Problem (cache-aside):**
```
T1: read miss → reads DB (v1)
T2: update DB to v2 → delete cache
T1: writes v1 into cache   ← stale forever (until TTL)
```

**Solutions:**

- Short TTLs as a safety net
- **Delete cache after DB write** (not update), plus **delayed double-delete** (delete again after ~1s)
- Versioned cache values: only `SET` if version is newer (Lua compare)
- **Lease-based gets (Facebook Memcache paper):** on a miss, the cache returns a lease token; a `SET` is accepted only with a valid lease, and a delete invalidates outstanding leases
- **CDC-driven invalidation:** tail the DB binlog/WAL and invalidate (ordered, reliable)

See [04-building-blocks/02-caching.md](../04-building-blocks/02-caching.md).

---

## 9. Concurrent edits to the same document

**Problem:** two users edit the same paragraph. Last-write-wins loses one edit.

**Solutions:** OT (Google Docs), CRDTs (Figma-like, Automerge/Yjs), or locking sections. See [06-case-studies/12-collaborative-editor.md](../06-case-studies/12-collaborative-editor.md).

---

## 10. Distributed cron: job runs twice or never

**Problem:** the scheduler runs on 3 instances for HA, so every job fires 3 times. With one instance, it's a single point of failure.

**Solutions:**

- Leader election (only the leader schedules), with fencing
- **Claim with conditional update:** `UPDATE jobs SET owner=?, lease_until=? WHERE id=? AND (owner IS NULL OR lease_until < now())`
- `SELECT ... FOR UPDATE SKIP LOCKED`
- And always **idempotent jobs**, because even with leases, a paused worker might double-run

See [06-case-studies/11-job-scheduler.md](../06-case-studies/11-job-scheduler.md).

---

## 11. Rate limiting race

**Problem:** `GET count; if count < limit: INCR`. Two requests both pass at limit−1.

**Solution:** atomic `INCR` and then compare (the over-limit request is rejected after incrementing), or a Lua script for token bucket. See [06-case-studies/02-rate-limiter.md](../06-case-studies/02-rate-limiter.md).

---

## 12. Unique username / email registration

**Problem:** two users register "alice" at the same time across different app servers.

**Solutions:**

- **Unique index** in the DB (the only correct answer for a single DB)
- Sharded DB: unique index works within a shard, so **shard by username** for the uniqueness table (separate from the user table sharded by user_id)
- Multi-region: route "claim username" to a single home region, or use a globally consistent store (Spanner, DynamoDB global tables do **not** guarantee this, since they're LWW)

---

## 13. Read-your-writes after a write

**Problem:** a user posts a comment, refreshes, and the request hits a replica that hasn't seen it.

**Solutions:** read from the leader for a short window after a write; sticky sessions; pass a write token (LSN or timestamp) and require the replica to be at least that fresh; optimistic UI on the client.

---

## 14. Money transfer between shards

**Problem:** debit account A (shard 1) and credit account B (shard 2) atomically.

**Solutions:**

- 2PC (atomic, but blocking, coordinator SPOF, latency)
- **Saga** with compensations (debit A → credit B; on failure, refund A)
- **Ledger with an intermediate state:** write a "transfer pending" journal entry, then apply both sides idempotently
- Avoid it: co-locate related accounts, or use a distributed SQL DB (Spanner/CockroachDB) that does 2PC over Paxos groups for you

See [03-distributed-systems/07-distributed-transactions.md](../03-distributed-systems/07-distributed-transactions.md).

---

## 15. Long-running transactions and stale holds

**Problem:** a user starts checkout, the item is held, and the user abandons. The item is stuck.

**Solutions:** TTL holds + a sweeper, a delayed message to expire the hold (SQS delay / scheduled message), or a lazy check at read time (`status=HELD AND expires_at > now()`).
