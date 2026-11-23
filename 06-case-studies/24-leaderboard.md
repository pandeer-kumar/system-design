# Case Study 24: Real-Time Leaderboard (gaming)

> Tests: sorted data structures, rank queries at scale, sharding a globally ordered structure, and concurrent score updates.

## 1. Requirements

**Functional**
- Update a player's score (incremental or set-high-score) after a match
- Top N players (global, per region, per friend group)
- A player's own rank and the players around them
- Time-scoped boards (daily, weekly, season)

**Non-functional**
- 100M players, 10M DAU; 50K score updates/s at peak
- Rank queries < 100ms; leaderboard updates visible within seconds

## 2. Redis sorted sets (the standard answer)

- `ZINCRBY lb:season:5 <delta> <player>` (atomic increment), or `ZADD lb GT <score> <player>` (keep the max; atomic).
- Top N: `ZREVRANGE lb 0 N-1 WITHSCORES`, O(log n + N).
- Rank: `ZREVRANK lb player`, O(log n) (skip list with span counts).
- Around me: rank r → `ZREVRANGE lb r-5 r+5`.
- 100M members × ~100 bytes ≈ 10 GB in one sorted set: fits on one large node, but it's a single hot key for writes.

**Concurrency:** all operations are atomic (single-threaded Redis). No read-modify-write races if you use `ZINCRBY`/`ZADD GT` instead of `ZSCORE` then `ZADD`.

## 3. Scaling beyond one node

**Option A: Shard by score range**
- Shard 1: scores 0–1,000, shard 2: 1,000–10,000, ... Top N reads from the highest shard. Rank = count of players in higher shards (cached counts) + rank within the shard.
- Players move between shards when their score crosses a boundary (move = remove + add). Skewed distribution means uneven shards, so tune the boundaries.

**Option B: Shard by player (hash), scatter-gather for the top N**
- Each shard keeps its own sorted set. Top N = top N from each shard → merge (K shards × N items).
- **Exact rank is hard:** you need the sum over shards of `ZCOUNT(score > mine)`. A K-way query, acceptable for a few shards.

**Option C: Approximate rank for the long tail**
- Exact rank for the top 10K (single sorted set of top players); for everyone else, compute an approximate rank from a **score histogram** (bucket counts → percentile: "Top 12%"). Most games do this.

## 4. Durability and source of truth

- Scores are persisted in a DB (match results, player stats). Redis is the derived, rebuildable view.
- Pipeline: match service → Kafka (`score_updated`, keyed by player) → leaderboard updater → Redis. Idempotent by match_id (dedupe so retries don't double-add): keep a processed-matches set or use `ZADD GT` with absolute scores.
- Rebuild a board from the DB if Redis is lost.

## 5. Time-scoped boards

- A separate key per period (`lb:daily:2026-11-23`) with a TTL; a write updates all active scopes.
- Season reset = new key.

## 6. Friend leaderboards

- For a small friend list (≤ 500): fetch the friends' scores (`ZMSCORE`, or a hash of scores) and sort at read time.
- Precomputing per-user friend boards is too costly (fan-out on every score change).

## 7. Ties

- Tie-break by the earlier achievement time: encode it into the score, e.g., `score * 10^10 + (MAX_TS - ts)`, so it stays a single float/int sort key. Watch the 53-bit float precision of Redis sorted set scores.

## 8. Failure modes

| Failure | Handling |
|---|---|
| Redis primary fails | Replica promotion; possible loss of the last few updates → re-apply from Kafka (idempotent) |
| Hot write key | Batch updates per player per second; shard by score range |
| Cheating (impossible scores) | Server-authoritative scoring, anomaly detection, quarantine before display |
