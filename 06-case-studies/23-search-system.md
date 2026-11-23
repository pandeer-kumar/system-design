# Case Study 23: Search System (Twitter Search / E-commerce Search / Log Search)

> Tests: inverted indexes at scale, near-real-time indexing, sharding strategy, scatter-gather tail latency, and ranking.

## 1. Requirements (e-commerce product search; variations noted)

**Functional**
- Keyword search with filters (category, price, brand), facets (counts per filter), sorting
- Typo tolerance, synonyms
- Newly added or updated products searchable within ~1 minute
- Ranking by relevance + business signals (sales, ratings, ads)

**Non-functional**
- 500M products; 50K QPS peak; p99 < 200ms
- Index updates: 10K/s (price and stock changes)
- Highly available

## 2. Architecture

```
Write path:
  Catalog DB → CDC (Debezium) → Kafka → Indexer (enrich, denormalize: product + seller + reviews summary)
     → Search cluster (Elasticsearch/OpenSearch or custom Lucene-based)

Read path:
  Client → Search API → Query understanding (spell correction, synonyms, category classification, intent)
     → Retrieval: scatter to all shards (BM25 + filters [+ vector ANN for semantic recall])
     → Merge top-K → Re-rank (ML: learning to rank with features) → Personalization → Facets → Response
  Result cache for head queries (popular queries make up a big share of traffic)
```

## 3. Index design

- **Document-partitioned shards** (each shard has a subset of products with their full index). 500M products → ~50 shards of 10M.
- Replicas ×3 for throughput and availability.
- **Fast-changing fields** (price, stock) are frequent updates. In Lucene, an update means delete + reinsert, which is expensive. Options: keep volatile fields in a separate fast store (doc values updated in place / external lookup at ranking time), or batch updates.

## 4. Near-real-time indexing

- CDC → Kafka partitioned by product_id (per-product ordering).
- Indexer uses **external versioning** (DB version/LSN) so out-of-order or replayed updates don't overwrite newer data.
- Refresh interval ~1s (a trade-off between freshness and indexing throughput).
- Full reindex (new index + alias swap) for mapping changes; dual-write during the transition from the Kafka log (replay from an offset).

## 5. Scatter-gather and tail latency

- Each query hits all ~50 shards, so latency = the slowest shard.
- Mitigations: adaptive replica selection (pick the fastest replica), hedged requests, shard-level timeouts with partial results, fewer and larger shards for latency-critical use cases, and **tiered indexes** (search a small "head" index of popular products first).

## 6. Ranking pipeline

- Stage 1: BM25 + filters → top 1,000 per shard (cheap)
- Stage 2: merged top ~500 → ML re-ranker (GBDT/neural, features: text match, CTR, conversion rate, price competitiveness, freshness, personalization)
- Business rules: ads/sponsored slots, diversity, out-of-stock demotion

## 7. Variations

- **Twitter search:** time-ordered, append-mostly. Shard by **time** (recent index in memory, Earlybird), plus a historical archive; the query fans out to the recent shards first.
- **Log search (Splunk/ELK/Loki):** massive ingest, rare queries. Time-partitioned indexes, cheap storage, label-only indexes with brute-force scanning of compressed chunks (Loki), hot/warm/cold tiers.

## 8. Failure modes

| Failure | Handling |
|---|---|
| Shard replica down | Other replicas serve; rebuild from a snapshot + Kafka replay |
| Indexing lag | Monitor lag; degrade freshness, not availability |
| Query of death (heavy wildcard) | Query validation, timeouts, circuit breakers per query pattern |
| Index corruption | Snapshots to S3; rebuild from the source of truth (DB + Kafka) |
