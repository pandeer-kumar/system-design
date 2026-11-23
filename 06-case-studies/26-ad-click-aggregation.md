# Case Study 26: Ad Click Aggregation (real-time event aggregation)

> Tests: high-volume event ingestion, stream processing with event time and late data, exactly-once counting, hot keys, the OLAP serving layer, and reconciliation for billing correctness. Common at Meta, Google, Amazon, and any company with an ads business. Background: [Flink deep dive](../09-technology-deep-dives/08-stream-processing-flink.md).

## 1. Requirements

**Functional**

- Ingest ad click events (`click_id, ad_id, campaign_id, user_id, ts, ip, country, device`)
- Query: clicks for `ad_id` over the last M minutes (per-minute granularity), with filters (country, device)
- Top N most-clicked ads in the last M minutes (per category/region)
- Data feeds **billing** (advertisers pay per click), so final numbers must be accurate

**Non-functional**

- 1B clicks/day ≈ **10K/s average, 50K/s peak**; 2M active ads
- Dashboard freshness: a few seconds to a minute
- **Correctness:** no double counting, no lost clicks (money)
- Query latency < 1 s for dashboards
- Handle late and duplicate events (mobile clients retry; logs arrive late)

## 2. Estimation

- 50K events/s × ~200 bytes = 10 MB/s raw → ~1 TB/day raw (keep raw in S3 for reprocessing and audits)
- Aggregated: 2M ads × 1,440 minutes × a few dimension combinations ≈ billions of rows/day before rollup → minute data kept ~30 days, hourly/daily rollups kept longer

## 3. High-level design

```
Ad servers / click redirect service ─► Click log ─► Kafka "raw_clicks" (partition by ad_id)
                                                       │
                     ┌─────────────────────────────────┼──────────────────────────────┐
                     ▼                                 ▼                              ▼
     Stream aggregator (Flink)              Raw archive (S3 via Kafka Connect)   Fraud/bot detection
       dedup → filter → window → aggregate             │                         (features, rules, ML)
                     ▼                                 ▼
     Kafka "aggregated_clicks" ──► OLAP store     Batch recompute (Spark, hourly/daily)
     (Pinot/Druid/ClickHouse)        ▲                 │  reconciles and produces BILLING numbers
                                     │                 ▼
               Query service ────────┘          Billing DB (source of truth for invoices)
               (dashboards, top-N)
```

## 4. Deep dive: capturing clicks reliably

- Clicks typically go through a **redirect endpoint** (`/click?ad=…&sig=…` → 302 to the advertiser). The click is logged **before** redirecting.
- Log locally to disk or an agent first, then ship to Kafka asynchronously (never block the redirect on Kafka).
- Each click gets a **unique `click_id`** at the source (UUID or signed impression ID + timestamp), the key to deduplication later.
- Kafka: `acks=all`, RF=3, `min.insync.replicas=2`, idempotent producers.

## 5. Deep dive: the aggregation job

```
source(raw_clicks), event time = click ts, watermark = max_ts − 15 s, idleness detection
→ dedup: keyBy(click_id) with keyed state TTL 1 h (or partition-local by ad_id + click_id set with TTL)
→ validity filter: bot/fraud signals, invalid signatures, impression-click join (click must follow an impression within N min)
→ keyBy(ad_id) → tumbling 1-min event-time window → incremental count (+ per-dimension counts)
→ allowed lateness 5 min (emit updated counts as upserts); later events → side output → correction topic
→ sink: Kafka "aggregated_clicks" (transactional) → OLAP ingestion; key = (ad_id, window_start, dims)
```

**Exactly-once counting, end to end:**

1. Upstream duplicates (client retries): dedup by `click_id`.
2. Processing failures: Flink checkpoints (state + Kafka offsets) → replay from the checkpoint is exactly-once for state.
3. Output duplicates on replay: transactional Kafka sink (committed per checkpoint) **or** idempotent upserts keyed by `(ad_id, window_start)` into the OLAP store.

**Why not count with `UPDATE counts SET n = n + 1` per click?** 50K/s of single-row increments, with hot ads concentrating on single rows, plus no handling of windows, lateness, or replays. Stream processing with local state turns this into a few thousand batched upserts per minute.

## 6. Deep dive: hot ads

A Super Bowl ad gets 20% of all clicks → the `keyBy(ad_id)` subtask for it is overloaded and holds back the watermark for the whole job.

- **Two-phase aggregation:** first `keyBy(ad_id, hash(click_id) % 16)` and count per salted key per window; then `keyBy(ad_id)` and sum 16 partial counts.
- Or **local pre-aggregation** (combine within each upstream subtask before the shuffle).
- Same fix applies to top-N computation.

## 7. Deep dive: top-N most clicked ads

- From the per-minute aggregates: for "last M minutes," keep a sliding window per category with a **min-heap of size N** per window, or let the OLAP store answer `ORDER BY clicks DESC LIMIT N` over pre-aggregated data (Pinot/Druid handle this well with star-tree/rollup indexes).
- For approximate heavy hitters at massive key cardinality: **Count-Min Sketch + heap** (see [case study 27](27-top-k-trending.md)).

## 8. Serving layer

- **OLAP store** with real-time ingestion from Kafka (Apache **Pinot**, **Druid**, **ClickHouse**): columnar, sub-second aggregations over billions of rows, upsert support on primary key `(ad_id, minute, dims)`.
- Query service adds auth (advertisers see only their ads), caching for popular dashboards, and rollups (minute → hour → day) for long ranges.

## 9. Deep dive: reconciliation and billing correctness

Real-time numbers are **for dashboards**. Billing uses a **batch recompute** from the raw archive:

- Hourly/daily Spark job over raw clicks in S3: dedup, fraud filtering with fuller information (late-arriving fraud signals), joins with impressions.
- Compare batch totals vs streaming totals per ad per hour; alert on drift above a threshold (e.g., 0.1%); the batch result **overrides** for invoicing.
- This is the "Kappa for freshness + batch for truth" pattern, and the honest answer to "how do you guarantee billing accuracy?"

## 10. Failure modes

| Failure | Handling |
|---|---|
| Flink job crash | Restart from the latest checkpoint; Kafka retention (days) covers the replay |
| Kafka broker loss | RF=3, ISR failover |
| Late mobile events | Allowed lateness + side output + batch reconciliation |
| Duplicate events | Dedup by click_id (state TTL ≥ max expected duplicate delay) |
| Bug in aggregation logic | Fix and **replay** from Kafka or S3 into a new output table; switch over (immutable raw data makes this possible) |
| OLAP store down | Kafka buffers aggregated data; dashboards degrade; billing unaffected (batch path) |
| Click fraud bursts | Fraud filters in-stream; refunds or credits computed in batch |

## 11. Follow-ups

- **Filtering by many dimensions (country × device × OS):** pre-aggregate the common combinations (star-tree index in Pinot), and compute rare ones from finer data.
- **Data retention and privacy:** raw clicks with user IDs → limited retention, hashed or truncated IPs, GDPR deletion by user ID in raw storage.
- **Exactly-once vs effectively-once:** be explicit that "exactly-once" here means exactly-once *effect* on aggregates through dedup + checkpoints + idempotent sinks.
- **Why not Lambda with two codebases?** Use the same Flink code in streaming and batch mode where possible to avoid logic drift.
