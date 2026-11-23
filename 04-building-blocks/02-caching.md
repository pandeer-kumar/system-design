# Caching

> "There are only two hard things in Computer Science: cache invalidation and naming things." Phil Karlton

## Where caches live

```
Browser cache → CDN → API gateway cache → app in-process cache → distributed cache (Redis/Memcached) → DB buffer pool → OS page cache → disk cache
```

| Layer | Latency | Scope | Notes |
|---|---|---|---|
| Client (browser/app) | 0 | Per user | HTTP cache headers, ETags |
| CDN | 10–50ms (near user) | Global, per PoP | Static assets, cacheable API responses |
| In-process (Caffeine, Guava) | ~100ns | Per instance | Fastest; N copies to keep consistent; memory per instance |
| Distributed (Redis, Memcached) | ~0.5–1ms | Shared | One logical copy; network hop |
| DB buffer pool | — | DB | Automatic |

## Caching strategies

### Cache-aside (lazy loading): the default
```python
def get(key):
    v = cache.get(key)
    if v is None:
        v = db.read(key)
        cache.set(key, v, ttl=300)
    return v

def update(key, v):
    db.write(key, v)
    cache.delete(key)    # delete, don't set (avoids some races)
```

- ✅ Only caches what's requested; cache failure ≠ outage (falls back to DB, if the DB can take it).
- ❌ Misses are slow (3 trips); stale data possible; race conditions (below).

### Read-through
The cache library loads from the DB on a miss (the app talks only to the cache). Same semantics as cache-aside, cleaner code.

### Write-through
Write to the cache **and** the DB synchronously.

- ✅ Cache always fresh for written keys.
- ❌ Write latency increases; caches data that may never be read.

### Write-behind (write-back)
Write to the cache, then asynchronously flush to the DB.

- ✅ Very fast writes; can coalesce many writes (counters).
- ❌ **Data loss** if the cache dies before flushing; complex consistency.
- Good for: counters, analytics, view counts.

### Write-around
Write directly to the DB, bypass the cache; the cache fills on read. Good for write-once, read-rarely data.

### Refresh-ahead
Proactively refresh hot keys before expiry.

## Invalidation strategies

1. **TTL:** simplest; bounds staleness. Always set one as a safety net.
2. **Explicit delete on write:** app deletes the key after updating the DB.
3. **Event-driven / CDC invalidation:** tail the DB change log (Debezium, MySQL binlog) and invalidate. Reliable and ordered; decouples writers from cache logic. (Meta's McSqueal tailed MySQL binlogs to invalidate memcache.)
4. **Versioned keys:** `user:42:v17`. On update, bump the version so old keys age out. Great for immutable content; CDN-friendly (`app.3f2a1b.js`).

## Race conditions (know these cold)

### Race 1: stale set after delete (cache-aside)
```
1. Reader: cache miss
2. Reader: reads DB → v1
3. Writer: updates DB → v2
4. Writer: deletes cache
5. Reader: sets cache = v1      ← stale until TTL
```
**Fixes:**

- **Leases (Facebook memcache):** on a miss, the server hands out a lease token. `SET` requires a valid lease; a `DELETE` invalidates outstanding leases, so step 5 is rejected.
- **Delayed double delete:** delete, and delete again after ~500ms–1s.
- **Version-checked set:** store a version with the value and `SET` only if newer (Lua script).
- Short TTL as backstop.

### Race 2: update-cache instead of delete
```
Writer A: DB=1          Writer B: DB=2
Writer B: cache=2       Writer A: cache=1   ← cache stale
```
**Prefer delete over update.** Deletes are idempotent and order-insensitive.

### Race 3: DB write succeeds, cache delete fails
The cache stays stale. **Fixes:** retry the delete via a queue, CDC-based invalidation, and TTL.

## Thundering herd / cache stampede

A hot key expires and thousands of concurrent requests recompute it.

**Fixes:**

- **Single-flight / request coalescing:** one in-flight recompute per key per process; the rest await it.
- **Distributed mutex:** `SET lock:k NX PX 3000`; losers wait briefly and re-check, or serve stale.
- **Stale-while-revalidate:** keep a soft TTL (logical expiry inside the value) and a hard TTL; past the soft TTL, one request refreshes and the others get the stale value.
- **Probabilistic early refresh (XFetch).**
- **TTL jitter:** `ttl = base + random(0, base*0.1)` to avoid synchronized expiry.
- **Pre-warm** after deploys or cache-node replacement.

## Hot keys

One key (a celebrity profile, a viral post) receives so much traffic it saturates one cache node.

**Fixes:**

- **Local in-process cache** (L1) in front of Redis (L2) for the hottest keys (a short TTL like 1–5s keeps it fresh enough)
- **Key replication:** store `k#1..k#N` on different shards; readers pick randomly; writers update all
- **Hot key detection:** client-side sampling, Redis `--hotkeys` (LFU), proxy-level top-K
- **CDN caching** for public content

## Cache penetration, breakdown, avalanche (common terms in interviews)

| Problem | Description | Fix |
|---|---|---|
| **Penetration** | Requests for keys that **don't exist** always miss and hit the DB (attack or bug) | Cache negative results (short TTL); **Bloom filter** of valid keys in front |
| **Breakdown** | A single hot key expires → stampede | Mutex/single-flight, never-expire hot keys + background refresh |
| **Avalanche** | **Many keys** expire at once, or the cache cluster dies | TTL jitter; HA cache (replicas); circuit breaker + rate limit to the DB; warm-up |

## Eviction policies

| Policy | Notes |
|---|---|
| LRU | Common default; vulnerable to scans (one big scan flushes the hot set) |
| LFU | Keeps frequently used; slow to adapt to changing popularity (use decay) |
| **W-TinyLFU** (Caffeine) | Admission filter + LRU windows; near-optimal hit rates |
| FIFO / random | Cheap; random is surprisingly OK |
| TTL-based | Expire by time |
| Redis | `allkeys-lru`, `allkeys-lfu`, `volatile-*`, `noeviction` |

## Redis vs Memcached

| | Redis | Memcached |
|---|---|---|
| Data types | Strings, hashes, lists, sets, sorted sets, streams, HyperLogLog, geo, bitmaps | Strings only |
| Threading | Single execution thread (I/O threads in 6+) | Multithreaded |
| Persistence | RDB snapshots, AOF | None |
| Replication | Primary-replica, Sentinel, Cluster | None (client-side sharding) |
| Atomic ops | Lua scripts, MULTI/EXEC, INCR | CAS, incr |
| Use | Rich structures (leaderboards, rate limits, queues, locks) | Pure, simple, high-throughput cache |

**Redis replication is async:** acknowledged writes can be lost on failover. Don't treat Redis as a durable source of truth unless you accept that (or use `WAIT`, or a managed product with stronger guarantees like MemoryDB, which has a multi-AZ transaction log).

## Consistency between cache and DB: how strong can you get?

- Cache-aside with delete + TTL: **eventual**, seconds of staleness in edge cases.
- CDC invalidation: eventual, with a small lag but reliable.
- Leases: removes most stale-set races.
- **Strong consistency with a cache is very hard.** If you need it, read from the DB, or make the cache the system of record with sync replication.

## What to cache (and what not)

✅ Read-heavy, expensive to compute, tolerant of staleness: user profiles, product pages, feeds, sessions, computed aggregates, auth tokens (with care), config.
❌ Rapidly changing data with strict consistency (balances), data with low reuse, huge objects with low hit rates.

## Sizing

- **Working set:** the 80/20 rule. Cache ~20% of the data to serve ~80% of reads.
- Measure the **hit ratio**. Going from 90% to 99% cuts DB load by **10×**.
- **Watch for:** a DB that can't survive a cold cache. If the cache is load-bearing, it's part of your availability story (replicas, warm-up, rate limiting on misses).

## Interview sound bites

- "Cache-aside with delete-on-write and a 5-minute TTL backstop; invalidation driven by CDC from the DB binlog so we don't depend on every writer remembering to invalidate."
- "For the celebrity hot-key problem, a 2-second in-process cache in front of Redis absorbs 99% of reads."
- "To prevent a stampede on expiry, single-flight per key plus stale-while-revalidate."
- "The DB can't handle a cold cache at peak, so we need cache replicas, gradual warm-up, and a rate limiter on cache-miss traffic."
