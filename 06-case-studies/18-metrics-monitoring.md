# Case Study 18: Metrics and Monitoring System (Datadog / Prometheus / Monarch)

> Tests: very high write throughput, time-series storage and compression, cardinality, aggregation, alerting reliability, and the meta-problem of monitoring the monitoring.

## 1. Requirements

**Functional**
- Ingest metrics (counters, gauges, histograms) with tags/labels from millions of hosts and containers
- Query: time ranges, aggregations (sum, avg, p99), group-by tags, rates
- Dashboards; alerting rules evaluated continuously; notifications
- Retention: high resolution (10s) for 15 days, downsampled (1m/1h) for 1+ years

**Non-functional**
- Ingest: **10M+ data points/s**
- Query latency: < 1s for dashboards over recent data
- **Alerting must be highly available**, more available than the systems it monitors
- Write path must never block producers (agents buffer)

## 2. Data model

A **time series** = metric name + set of tags (labels) → sequence of (timestamp, value).
```
http_requests_total{service="checkout", region="us-east", status="500"} → [(t1, 1043), (t2, 1051), ...]
```
**Cardinality** = the number of unique series. Unbounded tags (user_id) explode it. Enforce limits per tenant/metric.

## 3. Architecture

```
Agents (on hosts) → [batch, compress] → Ingestion gateways (auth, validate, rate limit per tenant)
   → Kafka (partitioned by series hash)  ← buffers bursts and decouples
   → Ingesters/Writers: in-memory head block per series (recent 2h), WAL
        → flush compressed blocks → Object storage (long-term) + index
   → Stream aggregation (pre-compute rollups, downsampling)
Query path: Query frontend (split by time, cache results) → queriers (fan out to ingesters for recent data + store gateways for historical blocks) → merge
Alerting: Rule evaluators (replicated, sharded by rule) → Alertmanager (dedup, grouping, silencing, routing) → PagerDuty/Slack
```

(This mirrors Cortex/Mimir/Thanos for Prometheus, M3 at Uber, and Monarch at Google.)

## 4. Deep dive: time-series storage and compression

- **Gorilla (Facebook, 2015) compression:**
  - Timestamps: **delta-of-delta** encoding (regular intervals compress to ~1 bit)
  - Values: **XOR** with the previous value (similar floats share bits) → ~1.37 bytes per point vs 16 raw
- Data organized in **blocks per time window** (e.g., 2h), immutable once flushed (like LSM SSTables); compacted into larger blocks; downsampled for long retention.
- **Inverted index** from tag → series IDs for queries like `service="checkout" AND status=~"5.."`.
- Columnar formats for long-term analytics.

## 5. Deep dive: write path at 10M points/s

- Agents batch (e.g., every 10s) and compress → far fewer requests.
- Partition by **series hash**, so all points for a series go to the same ingester (in-memory append, good compression).
- Replicate ingestion (each series written to 3 ingesters; queries dedupe) to survive ingester loss without gaps.
- WAL on ingesters for crash recovery of the in-memory head.
- Backpressure: if the backend is slow, Kafka buffers and agents buffer locally; drop the lowest-priority data first.

## 6. Deep dive: query path

- Recent data (last 2h) from ingesters' memory; older data from blocks in object storage via store gateways (with an index cache).
- **Query splitting** by time ranges in parallel; **results caching** of immutable older ranges.
- Pre-aggregated rollups (recording rules) for expensive dashboard queries.
- Protect against expensive queries: limits on series touched, query timeouts, per-tenant concurrency.

## 7. Deep dive: alerting reliability

- Alerting must work **when everything else is broken**. Run it on separate, minimal infrastructure.
- Rule evaluation is sharded across evaluators; each rule is evaluated by **2+ replicas** for HA. Alertmanager **dedupes** the identical alerts (a gossip-replicated cluster).
- **Dead man's switch:** an always-firing "watchdog" alert. If it stops arriving at the paging provider, the alerting pipeline itself is broken.
- Meta-monitoring: a separate, simpler monitoring stack (or another region) watches the main one.
- Alert on SLO burn rates; group related alerts; inhibit downstream alerts when an upstream dependency is down.

## 8. Push vs pull collection

| | Pull (Prometheus) | Push (Datadog, StatsD, OTLP) |
|---|---|---|
| How | Server scrapes `/metrics` endpoints | Agents send to collectors |
| Pros | Server controls the rate; easy to detect down targets ("up" metric) | Works behind NAT/firewalls, short-lived jobs, easy fan-in |
| Cons | Needs service discovery; hard across networks | Producers can overwhelm the backend; detecting silence needs extra logic |

## 9. Failure modes

| Failure | Handling |
|---|---|
| Ingester crash | Replication factor 3 + WAL replay |
| Cardinality explosion from a bad deploy | Per-tenant/per-metric series limits; reject new series beyond the limit; alert the owner |
| Kafka backlog | Data is delayed but not lost; alerting uses the freshest available data and flags staleness |
| Query of death | Query limits, isolation of query and ingest paths |

## 10. Follow-ups

- **Histograms and percentiles across hosts:** store bucket counts (or sketches such as DDSketch) so they can be merged; never average percentiles.
- **Logs and traces:** different storage. Logs: an inverted index or label-only index (Loki) + compressed chunks in object storage. Traces: by trace ID, with tail sampling.
