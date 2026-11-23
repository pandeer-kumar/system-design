# Case Study 19: Distributed Counter (likes, views, reactions)

> Tests: hot-key write contention, sharded counters, write-behind batching, approximate counting, and exactness vs scalability.

## 1. Requirements

**Functional**
- Increment/decrement counts (likes on a post, views on a video)
- Read counts (displayed on every post view)
- Per-user state for likes: did *I* like this? (toggle, no double-like)

**Non-functional**
- Some posts get **millions of likes in minutes** (a celebrity post), up to ~100K increments/s on one key
- Reads ≫ writes (every view displays the count)
- Display can be eventually consistent (seconds); **no double-counting of a user's like**

## 2. Why the naive approach fails

```sql
UPDATE posts SET like_count = like_count + 1 WHERE id = 42;
```
- One hot row: row-lock contention serializes every increment. A single DB row tops out at ~hundreds to a few thousand updates/s.
- A Redis `INCR` on one key: ~100K/s on one shard, and then that shard is saturated (hot key).

## 3. Separate the two concerns

1. **Like relationship** (correctness: one like per user per post): `likes(post_id, user_id)` with a **unique constraint**. Insert = like; delete = unlike. Idempotent by design.
2. **Aggregate count** (performance: approximate is OK): derived from the relationship events, asynchronously.

## 4. Solution options for the count

### Option A: Sharded counters
- Split the counter into N shards: `count:{post}:{0..N-1}`. Each increment goes to a random shard; reads sum all N (or a cached sum).
- N adapts to heat: 1 shard for normal posts, 100+ for viral ones.
- Firestore officially recommends this pattern ("distributed counters"). The same idea underlies Java's `LongAdder`.

### Option B: Write-behind aggregation (best at scale)
```
Like event → Kafka (partitioned by post_id) → stream aggregator (Flink)
   aggregates per post over 1–5s windows → single batched UPDATE count = count + Δ
   → counter store (DB/Redis) → cache for reads
```
- 100K likes/s on one post become **one write per second** of +100K.
- The like relationship is still written synchronously (or via the same stream with dedup).
- Exactly-once counting: Flink checkpoints + idempotent sink (`UPDATE ... WHERE last_applied_offset < :offset`).

### Option C: Local buffering in app servers
Each app server accumulates increments in memory and flushes every second. Simple; you lose a second of counts if a server crashes (acceptable for views, maybe not for likes).

### Option D: CRDT counters across regions
PN-Counter per region; merged asynchronously. Each region counts locally; global = sum. Good for multi-region active-active.

### Option E: Approximate counting
- View counts with uniques: **HyperLogLog** (unique viewers in ~12 KB with ~1% error).
- Display rounding ("1.2M") hides small inaccuracies anyway.

## 5. Recommended design

```
Like API:
  INSERT INTO likes(post_id, user_id) ON CONFLICT DO NOTHING   → if inserted: emit LikeAdded(post, user, event_id) via outbox
  (unlike: DELETE → emit LikeRemoved)

Count pipeline:
  Kafka (key=post_id) → Flink: window 1s per post, sum deltas → upsert counts table (count += Δ) idempotently
  → Redis cache (count:{post}) updated/invalidated → read path

Read:
  count from Redis (fallback DB); "did I like it?" from likes table / per-user cache / Bloom filter of user's liked posts
```

## 6. Read-side scaling

- The count of a viral post is read millions of times/min, so it's a hot read key. Use in-process caches (1–5s TTL), CDN-embedded counts for public pages, or key replication.
- **Read-your-writes for the liker:** the client increments optimistically in the UI; the server's eventually consistent count catches up.

## 7. Failure modes

| Failure | Handling |
|---|---|
| Aggregator crash | Restore from checkpoint; replay Kafka from the checkpointed offsets (exactly-once via idempotent sink) |
| Duplicate like events | Unique constraint on likes + event_id dedup |
| Counter drift (bugs) | Periodic reconciliation: recompute `COUNT(*)` from the likes table for a sample or for hot posts |
| Redis cache lost | Rebuild from the counts table |

## 8. Follow-ups

- **Exact counts needed (e.g., votes in an election, inventory)?** Then coordination: sharded counters with transactional sums, or a single-writer partition processing every increment in order.
- **Top-K most-liked posts in the last hour:** stream windowed counts → Count-Min Sketch + heap, or exact counts per post in Flink → sorted set.
