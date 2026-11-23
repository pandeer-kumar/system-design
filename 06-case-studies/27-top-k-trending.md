# Case Study 27: Top-K / Trending (heavy hitters at scale)

> "Top 100 most-played songs today," "trending hashtags right now," "most viewed videos in the last hour." Tests: exact vs approximate counting, probabilistic data structures, sliding windows, distributed merge of partial results, and hot keys.

## 1. Requirements

**Functional**
- `topK(k, window)` for windows like last 1 minute / 1 hour / 1 day (e.g., k ≤ 1,000)
- **Trending** (optional): items whose rate is unusually high vs their baseline, not just the most popular overall
- Per-region or per-category variants

**Non-functional**
- Input: 1M events/s (views, plays, hashtag uses) over ~1B distinct items
- Freshness: results updated within ~1 minute for short windows
- Query latency < 50 ms (results precomputed)
- Approximate results acceptable for "trending"; exact required for, e.g., chart rankings that are published or paid on

## 2. Why it's hard

- **Cardinality:** keeping an exact counter for 1B items in memory per window is ~tens of GB, and sliding windows multiply it.
- **Throughput:** 1M updates/s can't go to a central store row by row.
- **Distribution:** events for the same item land on many machines; local top-K lists can't simply be concatenated (an item can be #101 everywhere locally and #1 globally).

## 3. Approaches

### A. Exact: count everything, then select (MapReduce style)
- Batch (Spark) over the window's logs: `count by item → global top-K`. Exact, but latency = batch interval (minutes to hours).
- Streaming exact: Flink `keyBy(item)` with windowed counts → each subtask emits its local counts → a global top-K operator merges. Works when the number of **active** items per window is manageable (state in RocksDB).

**Correct distributed merge:** partition by **item** (not randomly), so each item's full count lives on exactly one node. Then each node's local top-K **is** a valid candidate list, and merging the per-node top-K lists gives the exact global top-K. (Merging top-K lists from randomly partitioned data is **wrong**.)

### B. Approximate: Count-Min Sketch + heap
- **Count-Min Sketch (CMS):** a d × w matrix of counters with d hash functions. Increment: for each row i, `C[i][h_i(x)] += 1`. Estimate: `min_i C[i][h_i(x)]`. **Never underestimates**; overestimates by at most ε·N with probability 1−δ (w = e/ε, d = ln(1/δ)). Memory is fixed (e.g., a few MB) regardless of cardinality.
- Keep a **min-heap of size k** of candidate items with their estimated counts; on each event, update the CMS, and if the estimate beats the heap minimum, insert or update.
- **Mergeable:** sketches from different machines with the same hash functions are added cell-wise. That makes distributed aggregation trivial.
- Alternatives: **Space-Saving / Misra-Gries** (deterministic heavy-hitter algorithms with guaranteed error bounds; keep only ~k/ε counters), **HeavyKeeper** (better accuracy for top-K under skew).

### C. Hybrid (what production systems do)
Approximate fast path for real-time "trending" + exact batch path for the official numbers (the same "fast and approximate, then slow and exact" split as in ad click aggregation).

## 4. Architecture

```
Events → Kafka (partitioned by item_id) →
   Stream job (Flink):
     per subtask: windowed counts per item (exact for active items) or CMS + local heap
     every N seconds: emit local top-K' (K' = a few × K) for each window
   → global merge operator (single, low volume: #subtasks × K' entries) → top-K per window
   → Results store (Redis sorted sets / KV: key = (window, region, category) → ranked list)
Query API → reads precomputed lists (cached, CDN-able)
Batch (Spark, hourly/daily) → exact counts → overwrites official charts
```

### Sliding windows efficiently
- Keep counts in **time buckets** (e.g., per minute) per item. The last hour = the sum of 60 buckets. Update: add the newest bucket, subtract the expiring one. That's O(1) per bucket per item, rather than recounting.
- With sketches: one CMS per minute bucket; the hour sketch = the sum of 60 sketches (they're additive), and you subtract the expired one.
- Redis variant for moderate scale: `ZINCRBY topk:{minute} 1 item` per minute bucket, then `ZUNIONSTORE` over the last 60 buckets with a TTL; read `ZREVRANGE 0 k-1`. Simple and exact, but a hot key per bucket (shard buckets by item hash and merge).

## 5. Deep dive: hot items

A viral song: one `keyBy(item)` subtask gets a huge share of the traffic.
- **Pre-aggregate before the shuffle** (each upstream subtask sums counts per item per second, then sends one record per item per second instead of one per event).
- Or salt the key (`item#0..#N`) and sum in a second stage.

## 6. Trending ≠ most popular

"Trending" means growth relative to normal:
- Score = (count in the recent window) / (baseline expected count for this time), or a z-score against a moving average, or an exponentially decayed score: `score = Σ e^{−λ(now − t)}` with a short half-life, compared against a longer half-life.
- Require a minimum volume (avoid an item going from 1 to 5 uses being "trending").
- Filter spam and coordinated manipulation (count unique users, not raw events; HyperLogLog per item for distinct users).

## 7. Failure modes

| Failure | Handling |
|---|---|
| Stream job restart | Checkpointed state (counts or sketches) + Kafka replay |
| Merge operator down | Results store keeps serving the last computed lists (slightly stale) |
| Skewed partition | Pre-aggregation and salting |
| Approximation error near the cut-off | Compute K' > K candidates and re-rank; publish only exact numbers from batch for official rankings |
| Bot inflation | Distinct-user counting, rate limits per user, fraud filters before counting |

## 8. Interview sound bites

- "Partition by item ID so each item's count is complete on one node; then merging the local top-K lists is exact."
- "For trending over a billion items, a Count-Min Sketch per minute bucket plus a heap gives fixed memory and mergeable partial results; the hourly batch job publishes the exact chart."
- "A sliding one-hour window is 60 per-minute buckets; I add the newest and subtract the expired bucket, so the update cost doesn't depend on the window length."
