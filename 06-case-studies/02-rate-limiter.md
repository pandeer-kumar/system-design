# Case Study 02: Distributed Rate Limiter

> Tests: atomicity under concurrency, Redis internals, latency budgets, multi-region trade-offs, failure handling.

## 1. Requirements

**Functional**

- Limit requests per key (user, API key, IP, tenant) per time window, with configurable rules: `free tier: 100 req/min`, `POST /login: 5/min per IP`
- Return 429 with `Retry-After` when exceeded
- Multiple rules per request (per-user AND per-endpoint AND global)

**Non-functional**

- Low latency overhead: **< 1–2ms p99**
- Highly available. The limiter must not become the outage.
- Accurate enough (small over-admission OK for most rules; strict for security rules)
- Scale: 1M+ RPS across the fleet, millions of keys

## 2. Where it runs

| Option | Pros | Cons |
|---|---|---|
| Client-side | No server cost | Untrusted |
| **API gateway / sidecar (middleware)** | Central, language-agnostic | Shared infrastructure |
| In-service library | Flexible, low latency | Duplicated logic |

Choose: **gateway/sidecar** (Envoy global rate limit service, Kong, custom) with a shared counter store.

## 3. Algorithm choice

See [04-building-blocks/08-rate-limiting.md](../04-building-blocks/08-rate-limiting.md). Choose **token bucket** (bursts allowed, intuitive) or **sliding window counter** (smooth, cheap). Both need O(1) state per key.

## 4. High-level design

```
Client → LB → Gateway [rate limit filter] ──(check)──> Rate Limit Service ──> Redis Cluster
                │                                        ↑
                └──> Upstream services        Rules config (DB/etcd, cached in memory, hot-reloaded)
```

Rules are loaded from a config store and **cached in memory** on each gateway (push updates via watch). Counter state lives in a **Redis Cluster** sharded by rate-limit key.

## 5. Deep dive: the race condition

**Naive (broken):**
```
count = GET rl:user42
if count < limit:
    INCR rl:user42     ← two gateways both read 99, both increment → 101
```

**Fix 1: INCR first, then compare** (fixed window):
```
n = INCR rl:user42:{window}
if n == 1: EXPIRE rl:user42:{window} 60
if n > limit: reject
```
`INCR` is atomic. (`INCR` + `EXPIRE` aren't atomic together: if the process dies in between, the key never expires. Use a Lua script or `SET key 0 EX 60 NX` first.)

**Fix 2: Lua script (token bucket), the standard answer.** Redis executes scripts atomically on its single thread:
```lua
-- KEYS[1] = bucket key; ARGV = capacity, refill_rate_per_sec, now_ms, cost
local b = redis.call('HMGET', KEYS[1], 'tokens', 'ts')
local capacity, rate, now, cost = tonumber(ARGV[1]), tonumber(ARGV[2]), tonumber(ARGV[3]), tonumber(ARGV[4])
local tokens = tonumber(b[1]) or capacity
local ts = tonumber(b[2]) or now
tokens = math.min(capacity, tokens + (now - ts) / 1000 * rate)
local allowed = 0
if tokens >= cost then tokens = tokens - cost; allowed = 1 end
redis.call('HSET', KEYS[1], 'tokens', tokens, 'ts', now)
redis.call('PEXPIRE', KEYS[1], math.ceil(capacity / rate * 1000) * 2)
return {allowed, tokens}
```

- **Use Redis server time** (`redis.call('TIME')`) or a consistent clock to avoid gateway clock skew affecting refill.
- **Multiple rules per request:** keys for different rules may live on different shards, so a single script can't touch them all. Either use **hash tags** (`{user42}:minute`, `{user42}:hour`) to co-locate a user's keys, or check rules independently (accept that one rule consumes a token even if another rejects; usually fine).

## 6. Deep dive: latency and scale

A Redis round trip (~0.3–1ms) per request is acceptable for most APIs. At extreme scale:

- **Local token caching / batched leasing:** each gateway leases a chunk of tokens (e.g., 10% of the limit) from Redis and serves locally; it refreshes when depleted. Far fewer Redis calls, slight inaccuracy.
- **Local approximate counting + async sync:** each node counts locally and periodically pushes deltas; the global count is reconciled. Over-admission ≤ nodes × sync interval × rate.
- **Two-tier:** local limiter (coarse, per-node share = limit / node_count) + global limiter only for keys near their limit.
- **Pipelining** and connection pooling to Redis.
- **Hot keys** (one huge tenant): that key's shard saturates. Split that tenant's limit across N sub-keys (each gets limit/N; route randomly) or use local leasing.

## 7. Deep dive: failure modes

| Failure | Decision |
|---|---|
| Redis shard down / timeout | **Fail open** (allow) for general limits, so availability wins; **fail closed** for security limits (login brute force). Use a tight timeout (e.g., 5ms) plus a circuit breaker so the limiter doesn't add latency during the outage. Fall back to a **local in-memory limiter** with a per-node share of the limit. |
| Redis failover loses recent counts (async replication) | Brief over-admission. Acceptable. |
| Config store down | Keep using the cached rules. |
| Clock skew between gateways | Use Redis `TIME` inside the script, or a window keyed by server time. |

## 8. Deep dive: multi-region

- **Exact global limits** need cross-region coordination on every request (+100ms). Unacceptable.
- **Options:**
    1. **Per-region limits:** split the limit across regions (static, or by traffic share). Simple; slightly wrong when traffic shifts.
    2. **Local enforcement + async global sync:** regions gossip their counts every ~1s and each enforces `local + others' last known`. Over-admission bounded by sync lag.
    3. **Home-region routing:** a tenant's limit lives in its home region; remote regions call it asynchronously or with leased tokens.
- Most companies choose (1) or (2). State it clearly: "Global limits are approximate within ~1s of traffic, which is fine for API quotas."

## 9. Response and client behaviour

- `429` + `Retry-After` + `X-RateLimit-Limit/Remaining/Reset`.
- Clients back off with jitter.
- Distinguish **throttling for protection** (shed) from **quota enforcement** (business).

## 10. Follow-ups

- **Rate limiting by cost** (e.g., GraphQL query cost, LLM tokens): token bucket with `cost` > 1.
- **Concurrency limits** (in-flight requests) instead of rate: Redis counter with incr/decr plus TTL safety, or local semaphores.
- **DDoS:** a rate limiter at the app layer isn't enough. You need edge/WAF/anycast absorption.
- **Observability:** metrics per rule (allowed, rejected), top throttled keys, Redis latency.
- **Testing accuracy:** simulate concurrent load against the limiter and measure over-admission.
