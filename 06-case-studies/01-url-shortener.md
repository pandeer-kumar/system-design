# Case Study 01: URL Shortener (bit.ly / TinyURL)

> A warm-up problem, but interviewers use it to test ID generation, caching, and scaling reads. Go deep on the parts that matter.

## 1. Requirements

**Functional**

- Shorten a long URL → short code (`sho.rt/aB3xY9k`)
- Redirect short → long
- Optional: custom aliases, expiration, analytics (click counts)

**Non-functional**

- Read-heavy (100:1)
- Redirect latency p99 < 50ms
- High availability for redirects (99.99%). A broken link is very visible.
- Short codes must be unique and ideally not guessable/enumerable

## 2. Estimation

- 100M new URLs/month → ~40 writes/s (peak ~200/s)
- 10B redirects/month → ~4K reads/s (peak ~20K/s)
- Storage: 100M × 12 months × 5 years × 500 bytes ≈ **3 TB**. Fits in one big DB or a small shard set.
- Code length: 62^7 ≈ 3.5 trillion. 7 characters is plenty.

## 3. API

```
POST /v1/urls  { long_url, custom_alias?, expires_at? }  → { short_url }
GET  /{code}   → 301/302 Location: long_url
```

**301 vs 302:** 301 (permanent) is cached by browsers, so there's less load but you lose analytics on repeat clicks. **302** (or 307) if you need click analytics. Most shorteners use 302 for that reason.

## 4. Data model

```
urls(code PK, long_url, user_id, created_at, expires_at)
```
A KV store (DynamoDB/Cassandra) or Postgres both work; the access pattern is a point lookup by code.

## 5. High-level design

```
Client → CDN/edge cache → LB → Redirect service → Redis cache → DB
                               Shorten service → ID generator → DB
                                     ↓ click events → Kafka → analytics (ClickHouse)
```

## 6. Deep dive: generating short codes

| Option | How | Pros | Cons |
|---|---|---|---|
| **Hash + truncate** | `base62(md5(long_url))[:7]` | Same URL → same code (dedup) | **Collisions**: must check and retry with salt; check-then-insert race → use conditional insert |
| **Random code** | 7 random base62 chars | Unguessable, no coordination | Collision check needed (`INSERT ... IF NOT EXISTS`); rare at low fill rates |
| **Counter + base62** | Global counter → base62 | No collisions, compact | Counter is a coordination point; **sequential codes are enumerable** |
| **Counter ranges (segments)** | Each server leases a range of 1M IDs from ZooKeeper/DB | No per-request coordination, no collisions | Gaps on restart (fine), still sequential within range |
| **Pre-generated key service (KGS)** | Offline generate unique random codes into a "free keys" table; servers claim batches | Fast, unguessable, no collisions | Extra service; must atomically mark keys used |

**Recommended:** counter ranges (or Snowflake IDs) + **a bijective scramble** before base62 (e.g., multiply by a large odd constant mod 62^7, or a small Feistel network). You get collision-free codes without per-request coordination, and they're not trivially enumerable.

**Concurrency points:**

- Custom aliases: `INSERT ... IF NOT EXISTS` / unique PK. Never check-then-insert.
- KGS: two servers must not claim the same batch, so use `UPDATE ... SET claimed_by=? WHERE batch_id=? AND claimed_by IS NULL`, or `SKIP LOCKED`.
- Range leasing: atomic increment on the counter row (or etcd/ZooKeeper).

## 7. Deep dive: read path at scale

- Cache-aside in Redis: `code → long_url`. Hit ratio is very high (link popularity follows a power law).
- **In-process LRU** on redirect servers for the hottest links (a viral link can get 100K RPS).
- **CDN/edge caching** of redirects (cache the 302 for a short TTL). Edge workers can serve directly from an edge KV store.
- Negative caching for nonexistent codes (protects against scanning), plus a **Bloom filter** of valid codes.
- DB: replicate for reads; shard by code hash if needed (3 TB doesn't strictly need it).

## 8. Analytics without slowing redirects

- Redirect handler emits a click event **asynchronously** (fire into a local buffer → Kafka). Never block the redirect on analytics.
- Stream aggregation (Flink) → counts per code per minute → ClickHouse/Druid.
- Accept at-least-once and approximate counts for analytics; dedupe by event ID if exactness matters.

## 9. Failure modes

| Failure | Mitigation |
|---|---|
| Cache cluster down | DB must handle the read load, or degrade with rate limiting; replicate the cache |
| ID service down | Servers hold pre-leased ranges (minutes to hours of runway) |
| DB primary down | Redirects keep working from the cache and replicas; writes fail over |
| Malicious URLs | Scan on creation (Safe Browsing API), async re-scans, interstitial warnings |
| Abuse (spam creating millions of links) | Rate limit per user/IP, CAPTCHA |

## 10. Follow-ups

- **Expiration:** TTL in DB (DynamoDB TTL) + lazy check on read + cache TTL ≤ remaining lifetime.
- **Same long URL → same short URL?** Needs an index on `long_url` hash (per user). Usually not worth it.
- **Multi-region:** codes are immutable, so replicate everywhere asynchronously; reads are local. Writes go to any region if ID ranges are region-partitioned (region bits in the ID).
- **Delete a link:** invalidate the cache and CDN (purge), and accept short staleness.
