# Case Study 13: Web Crawler (Googlebot-style)

> Tests: distributed work queues, politeness (per-host rate limiting), dedup at billions of scale, partitioning by host, and robustness against adversarial content.

## 1. Requirements

**Functional**
- Start from seed URLs, download pages, extract links, crawl recursively
- Store pages for indexing
- Respect robots.txt, avoid traps, re-crawl based on freshness

**Non-functional**
- Scale: 1B pages/month (~400 pages/s; Google-scale is far higher)
- **Politeness:** never overload a website (e.g., ≤1 request/s per host)
- Robust: handle malformed HTML, traps, slow servers, and failures
- Extensible: new content types and processing steps

## 2. Estimation

- 1B pages/month ≈ 400 pages/s, peak ~1K/s
- 500 KB avg page → 500 TB/month raw (compress ~5× → 100 TB)
- URL frontier: billions of URLs × ~100 bytes ≈ 100s of GB (on disk with in-memory buffers)

## 3. High-level design

```
Seeds → URL Frontier (prioritized + per-host politeness queues)
          ↓
     Fetcher workers (async I/O, DNS cache) ← robots.txt cache
          ↓
     Content store (S3/Bigtable) + content dedup (hash/SimHash)
          ↓
     Parser / Link extractor → URL normalizer → URL filter (robots, blocklist, trap detection)
          ↓
     "URL seen?" (Bloom filter + persistent store) → new URLs → URL Frontier
```

## 4. Deep dive: URL frontier (the heart of it)

Two goals: **priority** (important pages first) and **politeness** (per-host rate limits).

**Mercator-style design:**
```
Front queues (F1..Fn by priority) → prioritizer picks with bias toward high priority
          ↓
Back queues (B1..Bm), each containing URLs of a SINGLE host
          ↓
Heap of (next_allowed_fetch_time, back_queue) → fetcher takes a queue whose host is allowed now
```
- Each back queue maps to **one host**, and a host maps to exactly one back queue. After fetching from host H, set H's next allowed time = now + delay (from robots.txt `crawl-delay` or adaptive, based on response time).
- Back queues are refilled from the front queues when empty.

**Distribution:** partition the frontier **by host hash** across crawler nodes. Each node owns a set of hosts, so politeness is enforced locally without distributed coordination (**single owner per host**). Discovered URLs for hosts owned by other nodes are forwarded to them (batched).

## 5. Deep dive: dedup

**URL dedup ("have we seen this URL?"):**
- Normalize URLs first: lowercase the host, remove default ports and fragments, sort query params, remove tracking params.
- Billions of URLs: a **Bloom filter** in memory (~10 bits/URL for 1% FP; 10B URLs ≈ 12 GB) for a fast negative check, backed by a persistent store (RocksDB/Bigtable) of URL hashes (with metadata: last crawl time, checksum).
- A Bloom filter false positive means occasionally skipping a new URL, which is acceptable.

**Content dedup:**
- Exact: hash (SHA-256/MD5) of normalized content; ~30% of the web is duplicate.
- Near-duplicate: **SimHash** (Google used it for near-dup detection) or MinHash. Pages within a small Hamming distance are duplicates.

## 6. Deep dive: fetching at scale

- Async I/O (thousands of concurrent connections per node), connection reuse per host.
- **DNS resolution is a bottleneck:** local caching resolvers, prefetching.
- Timeouts, max page size, max redirects.
- Respect `robots.txt` (cached per host with a TTL); honour `noindex`/`nofollow`.

## 7. Deep dive: traps and robustness

- **Spider traps:** infinite calendars, session IDs in URLs, dynamically generated links. Mitigations: max URL length, max depth per host, per-host page budgets, pattern detection (repeating path segments).
- Malicious/huge content: size limits, content-type filtering, sandboxed parsing.
- Poison pages that crash parsers: retry limits → DLQ.

## 8. Freshness and re-crawl

- Priority by importance (PageRank-ish, traffic) × change rate.
- Estimate change frequency per page (from history: did the checksum change?) and schedule re-crawl accordingly.
- Conditional requests (`If-Modified-Since`, `ETag`) save bandwidth.

## 9. Failure handling

- The frontier is durable (disk-backed queues, checkpointed). On node failure, its hosts are reassigned (consistent hashing) and the new owner loads that portion of the frontier.
- Fetch failures: retry with backoff; mark hosts as unhealthy and slow down for them.
- At-least-once processing of URLs is fine (dedup makes reprocessing harmless).

## 10. Follow-ups

- **JavaScript-rendered pages:** a headless browser rendering farm (expensive; prioritize).
- **Storage:** Bigtable with row key = reversed domain (`com.example.www/path`) groups a site's pages together (as in the Bigtable paper's webtable).
- **Priority with a politeness tension:** a high-priority host still can't be fetched faster than its limit, so spread high-priority work across many hosts.
