# Data Processing: Batch, Stream, Lambda, Kappa

> **Go deeper:** [Stream processing (Flink)](../09-technology-deep-dives/08-stream-processing-flink.md) · [Ad click aggregation](../06-case-studies/26-ad-click-aggregation.md)

## Batch processing

- Process a **bounded** dataset all at once (hourly/daily jobs).
- **MapReduce:** map (emit key-value pairs) → shuffle (group by key across machines) → reduce (aggregate per key). Fault tolerance by re-executing failed tasks (deterministic, inputs on durable storage).
- **Spark:** in-memory DAG of transformations; lineage-based recovery (RDDs); much faster than disk-based MapReduce for iterative jobs.
- Storage: data lakes (S3/GCS + Parquet/ORC columnar formats) with table formats (**Apache Iceberg, Delta Lake, Hudi**) for ACID, schema evolution, and time travel on the lake.
- Use: ETL, reports, ML training data, backfills, reconciliation.

### Joins at scale

- **Sort-merge join:** both sides sorted by key.
- **Broadcast (map-side) join:** a small table is copied to every worker.
- **Skew handling:** salt hot keys, split them, and handle them separately.

## Stream processing

- Process an **unbounded** stream continuously with low latency (ms–seconds).
- Engines: **Apache Flink** (the leader in stateful streaming), Kafka Streams, Spark Structured Streaming (micro-batch), Google Dataflow / Apache Beam, Apache Samza.

### Core concepts

- **Event time vs processing time:** the time the event happened vs the time it's processed. Use event time for correctness.
- **Windows:**
    - **Tumbling:** fixed, non-overlapping (every 1 min)
    - **Sliding/hopping:** overlapping (5-min window every 1 min)
    - **Session:** activity-based, closed after an inactivity gap
- **Watermarks:** "I believe I've seen all events up to time T." Triggers window computation. Late events (after the watermark) can be dropped, sent to a side output, or used to update results (allowed lateness).
- **State:** per-key state (counts, aggregates) stored locally (RocksDB in Flink), partitioned by key, checkpointed.
- **Exactly-once state:** Flink's **distributed snapshots** (Chandy-Lamport-style barriers through the stream) checkpoint operator state and source offsets consistently. On failure, restore the checkpoint and replay from those offsets. Exactly-once **end to end** additionally needs transactional or idempotent sinks (two-phase commit sinks).

### Stream joins

- **Stream-stream:** within a time window (click joined with impression within 10 min).
- **Stream-table:** enrich events with the latest table state (a CDC changelog materialized as a table).

## Lambda architecture

```
           ┌→ Batch layer (complete, accurate, slow) → batch views ─┐
Raw data ──┤                                                         ├→ Serving layer (merge)
           └→ Speed layer (real-time, approximate)  → RT views ─────┘
```

- ✅ Accurate batch results plus low-latency approximate ones.
- ❌ **Two codebases** for the same logic; merging complexity.

## Kappa architecture

```
Raw data → Durable log (Kafka, long retention) → Stream processor → Serving views
Reprocessing = replay the log with a new job version → swap
```

- ✅ One codebase, one paradigm.
- ❌ Requires long log retention (tiered storage) and a robust stream processor; heavy historical reprocessing can be slow.
- **The modern default:** streaming-first, with a lakehouse for historical analytics.

## Change Data Capture (CDC)

- Read the DB's replication log (Postgres logical decoding, MySQL binlog, Mongo change streams) and emit row changes as events.
- Tools: **Debezium**, AWS DMS, Maxwell, Fivetran.
- Uses: keep search indexes, caches, and warehouses in sync; outbox relay; microservice data integration; cache invalidation.
- ✅ No dual writes; captures every change, in commit order.
- Handle **initial snapshots** plus streaming, schema changes, and per-key ordering (partition by PK).

## Analytics serving

- **OLAP stores:** ClickHouse, Apache Druid, Apache Pinot (real-time ingestion from Kafka, sub-second aggregations, used for user-facing analytics at LinkedIn and Uber), BigQuery, Snowflake.
- **Pre-aggregation / rollups** (cubes) for dashboards.
- **Approximate algorithms:** HyperLogLog (distinct counts), Count-Min Sketch (frequencies/top-K), t-digest (percentiles). Trade a small error for massive memory savings.

## Probabilistic data structures (know these)

| Structure | Answers | Memory | Error |
|---|---|---|---|
| **Bloom filter** | "Is X in the set?" (no false negatives) | ~10 bits/element for 1% FP | False positives |
| **Counting Bloom / Cuckoo filter** | Membership with deletes | Slightly more | FP |
| **HyperLogLog** | "How many distinct?" | ~12 KB for billions (Redis `PFADD`) | ~0.81% std error |
| **Count-Min Sketch** | "How often has X appeared?" | Fixed (width × depth) | Overestimates |
| **Top-K (Heavy Keeper, Space-Saving)** | Most frequent items | Fixed | Approximate |
| **t-digest / DDSketch** | Percentiles | Small | Bounded relative error |
| **MinHash / LSH** | Similarity / near-duplicate detection | Small | Approximate |

Uses: Bloom filters in LSM reads, crawler URL-seen checks, cache penetration protection; HLL for unique visitors; CMS for trending hashtags and heavy-hitter detection (hot keys).
