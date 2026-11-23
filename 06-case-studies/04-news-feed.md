# Case Study 04: News Feed (Twitter / Instagram / Facebook)

> Tests: fan-out strategies, the celebrity (hot user) problem, caching, ranking, and consistency trade-offs.

## 1. Requirements

**Functional**

- Post (text/media)
- Follow users
- View home timeline (posts from people you follow), reverse-chronological or ranked
- Optional: likes/comments, notifications, search

**Non-functional**

- 300M DAU, 500M total users
- Timeline load p99 < 200–300ms
- Eventual consistency OK: a post can take a few seconds to appear in followers' feeds
- Read-heavy: ~100:1
- Highly available

## 2. Estimation

(See [estimation](../00-interview-framework/02-estimation.md).)

- Posts: ~150M/day ≈ 1.7K/s avg, ~5K/s peak
- Timeline reads: ~3B/day ≈ 35K/s avg, ~100K/s peak
- Average 200 followers → fan-out writes ≈ **350K/s**
- Celebrities: 100M+ followers

## 3. API

```
POST /v1/posts            {text, media_ids[]} → {post_id}
GET  /v1/feed?cursor=...&limit=20 → {posts[], next_cursor}
POST /v1/users/{id}/follow
```

## 4. Data model

```
posts(post_id PK [Snowflake, time-sortable], author_id, text, media_urls, created_at)   -- sharded by post_id or author_id
follows(follower_id, followee_id, created_at)   -- two tables/indexes: by follower and by followee
timeline_cache: user_id → [post_id, post_id, ...]  (Redis list / sorted set, capped ~800)
```

## 5. The core decision: fan-out on write vs read

### Fan-out on write (push)
When Alice posts, push the post ID into every follower's timeline cache.

- ✅ **Reads are O(1)**: fetch the precomputed list.
- ❌ Write amplification: 1 post × followers. **A celebrity with 100M followers = 100M writes per post.**
- ❌ Wasted work for inactive followers.
- ❌ Fan-out lag: followers see the post seconds to minutes later.

### Fan-out on read (pull)
At read time, fetch recent posts from everyone you follow and merge.

- ✅ No write amplification; always fresh.
- ❌ **Reads are expensive**: follow 1,000 people → 1,000 lookups and a k-way merge per timeline load.
- ❌ Hard to hit < 200ms at 100K QPS.

### Hybrid (what Twitter, Instagram, and Facebook do)

- **Normal users** (< ~10K–100K followers): fan-out on write.
- **Celebrities** (above the threshold): **not** fanned out. At read time, fetch the celebrities' recent posts (heavily cached, since everyone reads them) and **merge** them into the precomputed timeline.
- **Inactive users:** skip fan-out for users who haven't logged in for 30+ days; rebuild their timeline on demand when they return.

```
Read timeline(user):
   precomputed = redis.LRANGE(timeline:user, 0, 200)      # pushed posts
   celebs = followed_celebrities(user)                     # usually small set
   celeb_posts = multi-get recent posts of celebs (cached per celeb)
   merged = merge_by_time_or_score(precomputed, celeb_posts)
   hydrate(merged[:20])   # fetch post bodies, author info, counts (batch, cached)
```

## 6. High-level design

```
Write path:
Client → API → Post Service → Posts DB (sharded) + media to S3/CDN
                    ↓ (outbox / event)
                 Kafka "post_created"
                    ↓
              Fan-out workers ── read followers (Graph service) ──> Timeline cache (Redis cluster, sharded by user_id)
                    ↓
              Other consumers: search indexer, notifications, analytics

Read path:
Client → API → Feed Service → Timeline cache (+ celebrity merge) → Hydration (Post cache, User cache, Counters) → Ranking (optional) → response
```

## 7. Deep dive: fan-out workers at 350K writes/s

- Kafka topic partitioned by **author_id**; workers page through the follower list in batches of ~1K and issue **pipelined** Redis `LPUSH` + `LTRIM` (cap the list size).
- Large fan-outs (10K–100K followers) are split into **sub-tasks** (follower ID ranges) so that one popular user doesn't occupy a worker for minutes.
- **Prioritize active users:** fan out to recently active followers first.
- **Idempotency:** a retried fan-out might push duplicates. Use a sorted set (`ZADD timeline:u post_id score=ts`), which is naturally idempotent, or dedupe at read time.
- **Deletes:** fan out a delete (or a tombstone checked at hydration). Hydration filters deleted or hidden posts anyway, which is simpler and always correct.

## 8. Deep dive: caching layers

| Cache | Contents | Notes |
|---|---|---|
| Timeline cache | user → post IDs | Only for active users; rebuild on miss from the follow graph + posts |
| Post cache | post_id → post object | Hot posts replicated; **hot-key protection** for viral posts |
| User cache | user_id → profile | |
| Social graph cache | follower/followee lists | |
| Counters | likes/retweets per post | Sharded counters, eventually consistent ([case study 19](19-distributed-counter.md)) |

- Twitter's timeline cache historically ran on Redis clusters, storing **only IDs** (8 bytes each). Hydration happens separately.
- **Hot posts:** a celebrity post read 10M times/min. Use in-process caches on feed servers + key replication across Redis shards.

## 9. Deep dive: ranking (if asked)

- Candidate generation: the precomputed timeline + celebrity posts + recommended posts (out-of-network).
- Feature fetch (engagement, affinity with author, recency, media type).
- ML model scores the candidates; then apply diversity rules and dedup.
- Two-stage: a light model on ~1,000 candidates, a heavy model on the top ~100.
- Latency budget: retrieval 50ms, features 50ms, scoring 50ms, hydration 30ms.

## 10. Consistency considerations

- **Read-your-writes:** when Alice posts, she expects to see it immediately in her own feed. Inject her own recent posts into her timeline at read time (or write to her timeline synchronously).
- **Ordering:** Snowflake IDs give rough time ordering; slight misordering is acceptable.
- **Unfollow:** filter at read time (check the follow set during hydration) instead of synchronously purging the timeline.
- **Privacy changes** (a private account, a block): must filter at read time. Never rely only on the precomputed timeline for authorization.

## 11. Failure modes

| Failure | Mitigation |
|---|---|
| Fan-out lag (Kafka consumers behind) | Autoscale workers on lag; prioritize active users; read-path fallback merges recent posts from followees (pull) |
| Timeline cache node lost | Rebuild on demand from the graph + posts (expensive: rate limit rebuilds, warm gradually); replicas |
| Celebrity posts → hot key | Celebrity posts cached in-process on every feed server, short TTL |
| Viral spike (World Cup goal) | Pre-scaled fan-out capacity, load shedding of non-critical features (counts, recommendations) |

## 12. Follow-ups

- **Threshold for "celebrity"?** Tune dynamically by follower count and post frequency; recompute periodically.
- **Media:** upload to S3 via pre-signed URL, serve via CDN; posts reference media IDs.
- **Edit post:** posts are fetched by ID during hydration, so edits appear automatically.
- **Pagination:** cursor = (score/ts, post_id) of the last item.
- **Storage choice for posts:** Cassandra/Manhattan (Twitter) or sharded MySQL (Facebook TAO for graph and objects).
- **Facebook's approach:** largely **pull-based with heavy caching** (multifeed aggregator queries leaf servers holding recent activity in memory), because ranking needs a large candidate set anyway.
