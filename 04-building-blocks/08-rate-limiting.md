# Rate Limiting Algorithms

Full distributed design in [06-case-studies/02-rate-limiter.md](../06-case-studies/02-rate-limiter.md). This page covers the algorithms.

## Why rate limit
- Protect services from overload (self-inflicted or abusive)
- Fairness between tenants
- Cost control (paid third-party APIs)
- Security (brute-force login, scraping)
- Enforce business tiers (free: 100/min, pro: 10K/min)

## Algorithms

### 1. Fixed window counter
`count[user][floor(now/60s)]++`; reject if > limit.
- ✅ Simple, O(1) memory, one Redis `INCR` + `EXPIRE`.
- ❌ **Boundary burst:** 100 at 0:59 + 100 at 1:00 = 200 within 2 seconds.

### 2. Sliding window log
Store the timestamp of every request (Redis sorted set). Count entries in `[now − window, now]`.
- ✅ Exact.
- ❌ Memory O(requests): 10K/min limit means storing 10K timestamps per user.

```
ZREMRANGEBYSCORE key 0 (now-window)
ZCARD key            → if < limit:
ZADD key now uuid
EXPIRE key window
```
(Wrap in Lua or MULTI to make it atomic.)

### 3. Sliding window counter (approximation)
Weighted combination of the current and previous fixed windows:
```
estimate = prev_count × (1 − elapsed_fraction_of_current_window) + curr_count
```
- ✅ O(1) memory, smooths the boundary burst. Cloudflare reported ~0.003% error in practice.
- **Common choice in production.**

### 4. Token bucket
- A bucket of capacity **B** refills at rate **r** tokens/sec. Each request consumes 1 token (or a cost). Empty means reject.
- ✅ **Allows bursts up to B** while enforcing an average rate r. Intuitive for APIs.
- Store only `(tokens, last_refill_ts)` and **refill lazily** on each request:
  ```
  tokens = min(B, tokens + (now − last) × r)
  if tokens >= cost: tokens -= cost; allow
  ```
- Used by AWS API Gateway, Stripe, and most API rate limiters.

### 5. Leaky bucket
- Requests enter a queue (bucket) and are processed at a fixed rate. Overflow is rejected.
- ✅ **Smooths output to a constant rate**. Good for protecting a downstream that needs steady load.
- ❌ Bursts are queued (latency), not served.
- As a meter (without a queue), it's equivalent to token bucket. GCRA (generic cell rate algorithm) is an efficient leaky-bucket variant storing one timestamp ("theoretical arrival time"). Used by `redis-cell` and Stripe-style limiters.

### 6. Concurrency limiter
Limit **in-flight** requests rather than rate (a semaphore). Protects against slow requests piling up. Adaptive variants (Netflix `concurrency-limits`, TCP-Vegas/gradient-style) automatically discover the limit from latency.

## Comparison

| Algorithm | Burst handling | Memory | Accuracy | Best for |
|---|---|---|---|---|
| Fixed window | 2× burst at boundaries | O(1) | Low | Simple quotas (daily limits) |
| Sliding log | Exact | O(N) | Exact | Low-volume, strict limits (login attempts) |
| Sliding window counter | Smoothed | O(1) | ~High | General API rate limiting |
| Token bucket | Allows bursts to B | O(1) | High | APIs with burst tolerance |
| Leaky bucket / GCRA | Smooth output | O(1) | High | Traffic shaping, protecting downstreams |
| Concurrency limit | N/A | O(1) | — | Protecting from slow-request pileup |

## Where to rate limit

- **Edge/CDN/WAF:** IP-based, DDoS (Cloudflare, AWS WAF)
- **API gateway:** per API key/user/tenant
- **Service level:** per caller service (protect yourself)
- **Client-side:** self-throttling (respect `Retry-After`, adaptive client throttling as in the Google SRE book)

## Response

- `429 Too Many Requests` + `Retry-After` + `X-RateLimit-*` headers
- Or **degrade** instead of rejecting (serve cached or lower-fidelity results)
- **Load shedding by priority:** drop low-priority traffic first (background sync before user-facing requests)

## Distributed concerns (preview)

- **Atomicity:** use Redis Lua scripts (single-threaded execution means no race).
- **Latency:** a Redis round trip per request (~0.5ms). Use local token caches or batched synchronization for very high QPS.
- **Multi-region:** global exact limits need cross-region coordination (slow). Usually **per-region limits** (global limit / number of regions, rebalanced asynchronously) or async gossip of counts, which is approximate.
- **Fail open vs closed** when Redis is down: usually **fail open** (allow) for availability, except security-critical limits (login attempts).
