# Stream Processing Internals (Apache Flink): A Deep Dive

> Real-time aggregation questions ("count ad clicks per minute," "trending hashtags," "fraud detection," "live dashboards") hinge on stream processing. Interviewers probe event time vs processing time, watermarks and late data, state management, and how exactly-once actually works. Background: [data processing patterns](../05-patterns/05-data-processing.md).

## 1. Why a stream processor (and not just consumers + a DB)

A plain Kafka consumer updating a DB row per event works until you need:

- **Windows** ("per minute," "last 10 minutes, sliding")
- **Event time correctness** (events arrive late and out of order from mobile clients)
- **Large keyed state** (per-user, per-ad counters) without a DB round trip per event
- **Exactly-once results** after failures
- **Joins** between streams, or stream + table

Flink provides all of these with local state and consistent checkpoints. Alternatives: Kafka Streams (a library, Kafka-only), Spark Structured Streaming (micro-batch), Google Dataflow / Apache Beam (managed, the model Flink implements), Apache Samza, RisingWave/Materialize (streaming SQL databases).

## 2. Execution model

```
Source (Kafka, parallelism 8) → map/filter → keyBy(adId) → window(1 min) → aggregate → Sink (DB / Kafka)
       └─ each operator runs as N parallel subtasks; keyBy repartitions (network shuffle) by key hash
```

- **JobManager:** schedules the job, coordinates checkpoints, handles failover (HA via ZooKeeper or Kubernetes leader election).
- **TaskManagers:** worker processes with task slots that run operator subtasks.
- **keyBy** sends all events with the same key to the same subtask → **single writer per key**, so per-key state needs no locks (the same principle as Kafka partitions and actors).
- Operators are chained when possible (no serialization between them); network buffers between stages give **credit-based backpressure**: a slow sink slows the whole pipeline back to the source, which simply stops reading Kafka (lag grows; nothing is dropped).

## 3. Time

| | Processing time | Event time |
|---|---|---|
| Meaning | When the operator sees the event | When the event happened (timestamp in the event) |
| Results | Depend on load and delays; not reproducible | Correct and reproducible, including on replay |
| Cost | Simple, lowest latency | Needs watermarks and buffering |

**Use event time** for anything users or billing see.

### Watermarks
A **watermark W(t)** is the stream's assertion: "no more events with timestamp ≤ t are expected."

- Typically generated as `max_event_time_seen − allowed_out_of_orderness` (e.g., 5 s) per source partition.
- An operator's watermark is the **minimum** of its inputs' watermarks, so one idle or slow Kafka partition holds back everything. Use **idleness detection** (`withIdleness`).
- When the watermark passes a window's end, the window **fires**.

### Late data
Events arriving after the watermark passed their window:

- **Drop** them (default),
- **Allowed lateness:** keep window state for an extra period and emit **updated results** (the sink must handle upserts),
- **Side output:** route them to a separate stream for correction or auditing.

Trade-off: a bigger out-of-orderness bound means more complete results but higher latency. State it explicitly in the interview: "We'll fire per-minute windows 10 seconds after the minute ends, accept late events for 5 more minutes as upserts, and send anything later to a correction stream reconciled by the batch job."

## 4. Windows

| Window | Example | Notes |
|---|---|---|
| **Tumbling** | Clicks per ad per minute | Non-overlapping |
| **Sliding / hopping** | Last 10 min, updated every minute | Each event in several windows (10× state); use incremental aggregation |
| **Session** | User activity sessions with a 30 min gap | Windows merge as events arrive |
| **Global + custom trigger** | Top-K updated every N events | Advanced |

**Incremental aggregation** (`reduce`/`aggregate`) keeps one accumulator per key per window instead of buffering all events. Always prefer it.

## 5. State

- **Keyed state** (ValueState, ListState, MapState) scoped to the current key; operator state for sources/sinks (e.g., Kafka offsets).
- **State backends:**
    - **HashMap** (on the JVM heap): fastest, limited by memory.
    - **RocksDB** (embedded LSM on local disk): state far larger than memory (TBs per job); slower access; supports **incremental checkpoints**.
- **State TTL** to expire per-key state (e.g., dedup sets) so it doesn't grow forever.
- **Rescaling:** keys are grouped into **key groups** (max parallelism, e.g., 128 or 32,768); changing parallelism reassigns whole key groups from a savepoint. Set max parallelism high enough up front.

## 6. Fault tolerance and exactly-once

### Checkpoints (asynchronous barrier snapshotting, a Chandy-Lamport variant)

1. The JobManager injects **checkpoint barriers** into every source partition.
2. When an operator has received the barrier on **all** inputs (**alignment**), it snapshots its state asynchronously to durable storage (S3/HDFS) and forwards the barrier.
3. When all sinks acknowledge, the checkpoint is complete: it includes **source offsets + all operator state**, consistent with each other.
4. On failure: restart from the latest checkpoint, **rewind sources** to the stored offsets, and replay. State and offsets match, so every event affects state **exactly once**.

- **Unaligned checkpoints** let barriers overtake buffered data under backpressure (faster checkpoints, larger snapshots).
- **Savepoints:** manually triggered, portable checkpoints for upgrades, rescaling, and migrations.
- Checkpoint interval trade-off: a shorter interval means less replay after failure but more overhead (and for transactional sinks, more frequent commits = lower end-to-end latency).

### End-to-end exactly-once
Internal state is exactly-once; **output** is the hard part, because replay re-emits results. Options:

1. **Transactional sink (two-phase commit):** the Kafka sink writes in a Kafka transaction per checkpoint; it **pre-commits** on the barrier and **commits** when the checkpoint completes. Downstream `read_committed` consumers see results only after commit (latency ≈ checkpoint interval).
2. **Idempotent sink:** upsert by a deterministic key (`ad_id, window_start`) so replays overwrite the same rows. Simpler and usually preferred for DB sinks.
3. At-least-once + downstream dedup.

## 7. Joins

| Join | How | State cost |
|---|---|---|
| Window join | Events from both streams in the same window | Window contents |
| **Interval join** | Click within 0–10 min after impression (keyed by impression ID) | Buffers both sides for the interval |
| Stream–table (temporal) join | Enrich each event with the version of a dimension table valid at its event time (CDC changelog as the table) | The table's current versions |
| Lookup join | Query an external DB/cache per event (async I/O) | None, but external latency and load |
| Regular (unbounded) join in SQL | Keeps both sides forever | Grows unboundedly → set state TTL |

## 8. Classic interview pipeline: ad click aggregation

```
Clients → click logger → Kafka "clicks" (keyed by ad_id)
Flink:
  source (event time, watermark = max_ts − 10s, idleness 1 min)
  → dedup by click_id (keyed state with 1h TTL, or a Bloom filter per key)  ← at-least-once upstream → exactly-once counts
  → filter fraud/bots (rules + model features)
  → keyBy(ad_id) → tumbling 1-minute window → count (incremental)
  → sink: upsert (ad_id, minute) → OLAP store (Pinot/Druid/ClickHouse) and Kafka for downstream
Batch layer: hourly/daily recompute from raw clicks in S3 → reconciles and corrects (billing uses this)
```
Hot ad (huge campaign): pre-aggregate with a **two-phase aggregation**. First `keyBy(ad_id, random_salt 0..N)`, count per salted key, then `keyBy(ad_id)` and sum the N partials. This removes the single hot subtask.

See [case study 26](../06-case-studies/26-ad-click-aggregation.md) for the full design.

## 9. Operating streaming jobs

- **Monitor:** consumer lag per source partition, checkpoint duration and size, checkpoint failures, backpressure per operator, watermark lag (now − watermark), state size, restarts.
- **Upgrades:** take a savepoint, deploy the new version from it. Keep operator UIDs stable and state schemas compatible.
- **Skew:** one hot key overloads one subtask (the whole job's watermark waits). Salting and two-phase aggregation, as above.
- **Backfills:** run the same job in batch mode over historical data (Flink unifies batch and streaming), or replay Kafka/tiered storage.

## 10. Flink vs Kafka Streams vs Spark Structured Streaming

| | Flink | Kafka Streams | Spark Structured Streaming |
|---|---|---|---|
| Deployment | Cluster (JobManager/TaskManagers), K8s operator | **Library inside your app** | Spark cluster |
| Sources/sinks | Many | Kafka in, Kafka out | Many |
| Latency | ms (true streaming) | ms | ~100 ms–seconds (micro-batch); continuous mode is limited |
| State | RocksDB/heap + checkpoints to S3 | RocksDB + changelog topics in Kafka | State store + checkpoints |
| Event time / watermarks | Most complete | Grace periods, suppression | Watermarks |
| Exactly-once | Checkpoints + 2PC sinks | Kafka transactions (EOS v2) | Checkpoints + idempotent/transactional sinks |
| Best for | Complex, large-state, low-latency pipelines | Kafka-centric microservices | Teams already on Spark; unified batch + streaming SQL |

## 11. Interview questions

1. **Event time vs processing time?** Event time = when it happened (correct, reproducible); processing time = when processed (simple, nondeterministic). Use event time for business metrics.
2. **What's a watermark?** A monotonic assertion that no events older than t are expected. It triggers window computation; it's the minimum across inputs.
3. **How do you handle late events?** Allowed lateness with updated results, side outputs, or drop; reconcile with a batch job.
4. **How does Flink achieve exactly-once?** Barrier-based consistent checkpoints of state + source offsets; restore and replay on failure; transactional or idempotent sinks for the output.
5. **How do you handle a hot key?** Two-phase aggregation with key salting, or local pre-aggregation before the shuffle.
6. **Why does one idle Kafka partition stall the pipeline?** The operator's watermark is the min over inputs; an idle partition never advances. Mark idle sources.
7. **RocksDB vs heap state?** Heap is faster but bounded by memory and has GC pressure; RocksDB handles state much larger than memory, with incremental checkpoints, at higher per-access cost.
8. **Lambda vs Kappa here?** Kappa (streaming as the main path, replay for backfills) plus a batch reconciliation for billing-grade correctness is the common modern design.
