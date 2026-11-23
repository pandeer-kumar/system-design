# Observability: Metrics, Logs, Traces, SLOs

Mention observability in every design. It's a strong senior signal.

## The three pillars (plus one)

| | What | Tools | Cost profile |
|---|---|---|---|
| **Metrics** | Numeric time series (counters, gauges, histograms) | Prometheus, Datadog, M3, CloudWatch | Cheap per data point; **cardinality** drives cost |
| **Logs** | Discrete events with context | ELK/OpenSearch, Loki, Splunk, CloudWatch Logs | Expensive at volume; sample and use levels |
| **Traces** | A request's path across services (spans) | OpenTelemetry, Jaeger, Zipkin, Tempo, X-Ray | Sample (head-based or tail-based) |
| **Profiles** | CPU/memory flame graphs continuously | Pyroscope, Parca, Google Cloud Profiler | Low overhead sampling |

**OpenTelemetry** is the standard for instrumentation (vendor-neutral API, SDKs, collector).

## What to measure

### RED method (request-driven services)

- **R**ate (requests/sec)
- **E**rrors (failed requests/sec or %)
- **D**uration (latency histogram: p50, p95, p99, p99.9)

### USE method (resources: CPU, disk, network, pools)

- **U**tilization
- **S**aturation (queue length, wait time)
- **E**rrors

### Four golden signals (Google SRE)
Latency, traffic, errors, saturation.

### System-specific key metrics

| Component | Metrics |
|---|---|
| Queue/Kafka | **Consumer lag**, age of oldest message, DLQ size, throughput |
| Cache | Hit ratio, evictions, memory, latency, hot keys |
| DB | QPS, latency, replication lag, connection pool usage, lock waits, deadlocks, slow queries |
| Load balancer | 5xx rate, healthy hosts, connection count |
| Business | Orders/min, payment success rate, signups. **Often the best outage detector.** |

## SLI, SLO, SLA, error budgets

- **SLI (indicator):** a measured quantity. "Fraction of feed requests served successfully in <300ms."
- **SLO (objective):** a target. "99.9% over 30 days."
- **SLA (agreement):** a contract with consequences (refunds). Looser than the SLO.
- **Error budget:** 1 − SLO. At 99.9%, that's 43 min/month. **When the budget is spent, freeze risky launches and focus on reliability.** This aligns velocity with reliability.

### Alerting

- **Alert on symptoms (SLO burn), not causes.** "Users are getting errors" beats "CPU is 80%."
- **Multi-window, multi-burn-rate alerts:** page if burning budget 14× faster than sustainable over 1h (and 5m to confirm); ticket for slower burns.
- Every page must be **actionable** and have a runbook.

## Histograms and percentiles

- **You can't average percentiles** across hosts. Aggregate histograms, then compute percentiles.
- Prometheus histograms (fixed buckets), HDRHistogram, **t-digest**, DDSketch (relative-error guarantees; mergeable).
- **Coordinated omission:** load generators that wait for responses under-report latency during stalls.

## Cardinality (the cost and scale problem)

- Each unique label combination = one time series. `http_requests{user_id=...}` with 10M users = 10M series. **Don't put unbounded values (user ID, request ID) in metric labels.** Put those in logs or traces.
- High-cardinality analysis is the domain of event-based observability (Honeycomb-style wide events) or traces.

## Distributed tracing

- A **trace ID** is propagated through every hop (W3C `traceparent` header), and each service creates **spans** with timing and attributes.
- Shows which service in the chain is slow and where retries and fan-out happen.
- **Sampling:** head-based (decide at the start, e.g., 1%) is cheap but misses rare errors; **tail-based** (decide after completion, keep all errors and slow traces) is better but needs buffering in the collector.

## Logging best practices

- **Structured** (JSON) with trace ID, request ID, user/tenant ID
- Levels; sample debug logs; never log secrets or PII without redaction
- Centralized, with retention tiers (hot 7 days, cold 90 days in S3)

## Interview checklist for the wrap-up

- "Key SLOs: 99.95% availability for booking, p99 < 500ms."
- "Dashboards: RED per service, Kafka consumer lag, DB replication lag, cache hit ratio."
- "Alerts: SLO burn rate, lag above 5 min, payment success rate drop of more than 2% (a business metric)."
- "Tracing with OpenTelemetry for the cross-service checkout flow."
- "A reconciliation job that detects inconsistencies (orders without payments) and alerts."
