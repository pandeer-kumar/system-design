# Elasticsearch / OpenSearch Internals: A Deep Dive

> Whenever a design says "search," "filter and facet," or "log analytics," Elasticsearch (or its fork OpenSearch) is the likely component. Interviewers probe the write path (why it's near-real-time), sharding decisions, consistency, and how to keep it in sync with the primary database. Background: [search building block](../04-building-blocks/06-search.md), [search case study](../06-case-studies/23-search-system.md).

## 1. Cluster anatomy

| Node role | Job |
|---|---|
| **Master-eligible** | Cluster state: index metadata, mappings, shard allocation. One elected master; run 3 dedicated ones. |
| **Data** (hot/warm/cold/frozen tiers) | Store shards, execute indexing and search |
| **Coordinating** (every node; can be dedicated) | Receive client requests, scatter to shards, gather and merge results |
| Ingest | Pre-processing pipelines (parse, enrich) |

- **Index** = a logical collection of documents, split into **primary shards** (fixed at creation), each with **replica shards**.
- **Shard** = one Lucene index = many immutable **segments**.
- **Cluster state** is published by the master to all nodes. Very large cluster states (tens of thousands of shards, huge mappings) slow everything.

### Master election and split brain
- Before 7.0: `discovery.zen.minimum_master_nodes` had to be set to a majority by hand; misconfiguration caused **split brain** (two masters, divergent data).
- Since 7.0: a built-in quorum-based coordination layer (Raft-like voting configuration) that manages quorum automatically. Use 3 master-eligible nodes across 3 AZs.

## 2. Write path: why search is "near-real-time"

```
index request → coordinating node → routes to the PRIMARY shard: shard = hash(_routing or _id) % num_primary_shards
primary:
  1. validate + parse → add to in-memory indexing buffer
  2. append to TRANSLOG (WAL)                         ← durability (fsync per request by default)
  3. forward to all in-sync REPLICA shards in parallel → each does the same
  4. ack to client once replicas respond
later:
  refresh (every 1s default): buffer → new SEGMENT in the filesystem cache → now SEARCHABLE
  flush: Lucene commit (fsync segments to disk) + truncate translog
  merge: background merging of small segments into bigger ones; deleted docs purged
```

- **Refresh** makes documents visible to search; that's why there's ~1 s delay (`refresh_interval`). Use `?refresh=wait_for` for read-your-writes on a specific request (costly if overused). Increase the interval (30 s) or disable it during bulk loads.
- **Get by ID** is real-time (reads from the translog/version map if not yet refreshed).
- **Segments are immutable.** An update = mark the old doc deleted + index a new doc. Heavy updates mean heavy merging.
- **Translog durability:** `index.translog.durability=request` (fsync before ack, default) vs `async` (every 5 s, faster, may lose recent writes on crash).

### Replication model
- **Primary-backup**, not quorum: the primary waits for all **in-sync copies** (tracked by the master, similar to Kafka's ISR). A failed replica is removed from the in-sync set and re-recovered later.
- **Sequence numbers** (per-shard `_seq_no`) and **primary terms** (incremented on every primary change: a fencing token) let replicas sync only missing operations after failover, and let the cluster reject operations from a stale primary.
- `wait_for_active_shards` controls how many copies must be available **before** a write starts (not a quorum ack).

## 3. Read path: query then fetch

```
coordinating node:
  QUERY phase: send to one copy (primary or replica) of EACH shard
               each shard returns top (from + size) doc IDs + scores
  merge → global top N
  FETCH phase: get the actual documents for the top N from the owning shards
```
- **Adaptive replica selection** routes to the fastest copy (accounting for queue depth and response time).
- **Deep pagination is expensive:** page 1,000 with size 10 means every shard returns 10,010 entries. Default limit `index.max_result_window` = 10,000. Use **`search_after`** with a point-in-time (PIT) for deep paging, and the scroll/PIT APIs for exports.
- **Relevance:** BM25 scoring is computed per shard by default (term statistics are local). With few documents per shard, scores can be inconsistent (`dfs_query_then_fetch` fixes it at a cost).

### Data structures behind queries
| Structure | Serves |
|---|---|
| Inverted index (term dictionary as an FST + posting lists) | Full-text and term queries |
| **Doc values** (columnar, on disk) | Sorting, aggregations, scripting |
| BKD trees | Numeric, date, geo range queries |
| Stored fields / `_source` | Returning the original document |
| HNSW graphs | Vector (kNN) search |
| Filter cache (bitsets) | Repeated filter clauses (cheap, cacheable; use `filter` context instead of `must` for non-scoring clauses) |

## 4. Mappings and analysis

- **Mapping** = the schema: field types (`text` analyzed for full-text, `keyword` exact for filters/aggregations/sorting, numeric, date, geo_point, dense_vector, nested).
- **Analyzers:** character filters → tokenizer → token filters (lowercase, stemming, synonyms, n-grams for autocomplete).
- **You can't change a field's mapping in place.** Create a new index and **reindex**, then swap an **alias**. Always query through aliases.
- **Dynamic mapping explosion:** indexing arbitrary JSON keys (user-defined attributes, log fields) creates thousands of fields → huge cluster state and memory. Use `dynamic: strict` or `flattened` fields, and cap with `index.mapping.total_fields.limit`.
- **Nested vs object:** objects in arrays are flattened (cross-object matches are wrong); `nested` keeps them separate but costs more (each nested object is a hidden document).

## 5. Shard sizing and capacity planning

- **Target 10–50 GB per shard** (search use cases toward the lower end, logs toward the higher end) and stay below ~200M docs per shard.
- **Too many small shards** ("oversharding") is the #1 ES performance problem: each shard has fixed memory and thread overhead and bloats the cluster state. Keep shards per node in the low hundreds at most, sized relative to heap.
- **Too few shards** limits indexing parallelism and makes recovery slow (large shards take long to copy).
- Primary count is fixed, but you can `_split` (multiply) or `_shrink` an index, or use time-based indexes / **data streams** with **rollover** (new index when size/age is reached).
- **Replicas** add read throughput and availability; they cost indexing work (each replica re-indexes the document; segment replication in OpenSearch copies segments instead).
- Heap: ≤ ~31 GB (compressed object pointers); leave the rest of RAM to the OS file cache, which is where segments are served from.

## 6. Time-series and logs: ILM and tiers

- **Data streams + rollover**: write to an alias; roll to a new backing index at 50 GB or 1 day.
- **Index lifecycle management (ILM):** hot (fast SSD, indexing) → warm (read-only, force-merged) → cold/frozen (searchable snapshots on object storage) → delete.
- Deleting old data = deleting whole indexes (cheap), never `delete_by_query` on huge ranges.

## 7. Consistency and concurrency

- **Near-real-time:** a successful write isn't searchable until the next refresh.
- **Optimistic concurrency control:** each document has `_seq_no` and `_primary_term`. Update with `if_seq_no=…&if_primary_term=…`; conflict → `409`. Or **external versioning** (`version_type=external`): the write succeeds only if the supplied version is higher than the stored one. **This is how you make a CDC indexer safe against out-of-order and replayed events.**
- No multi-document transactions. Model so that each update touches one document.
- It's a **secondary index, not a system of record**. Keep the source of truth in a database, and be able to rebuild any index from it.

## 8. Keeping Elasticsearch in sync with the database

| Approach | Verdict |
|---|---|
| App dual-writes (DB then ES) | ❌ diverges on partial failure; ordering races between concurrent writers |
| Periodic batch reindex from DB | OK for small or slowly changing data; stale |
| **CDC: DB WAL → Debezium → Kafka (keyed by PK) → indexer → ES with external version = DB LSN/version** | ✅ ordered per key, replayable, idempotent |
| Outbox events → indexer | ✅ when you need denormalized documents built from domain events |

Plus: a **full rebuild path** (new index from a DB snapshot + replay Kafka from the snapshot's position, then swap the alias), and periodic **drift checks** (compare counts/checksums).

## 9. Failure scenarios

| Scenario | What happens |
|---|---|
| Data node dies | Replicas promoted to primary (primary term increments); the master re-allocates missing replicas to other nodes (after `delayed_timeout` to avoid needless copying on a quick reboot) |
| Master node dies | Remaining master-eligible nodes elect a new master (quorum) |
| Network partition | The side without a master quorum can't elect a master; its nodes reject writes |
| Cluster goes **red** | At least one primary shard unassigned → writes to that index fail, searches return partial results |
| Disk watermark exceeded (85/90/95%) | Shards stop being allocated → relocated → at the flood stage indexes become **read-only** |
| Heap pressure / long GC | Circuit breakers reject expensive requests (huge aggregations) to avoid OOM |
| Mapping explosion | Cluster state bloat, master instability |

## 10. Elasticsearch vs alternatives

| | Elasticsearch / OpenSearch | Solr | Typesense / Meilisearch | Postgres full-text | Vespa | ClickHouse / Loki (logs) |
|---|---|---|---|---|---|---|
| Strength | General search + analytics, ecosystem | Mature, similar Lucene base | Simple, fast instant search for small/medium data | No extra system | Large-scale ranking + vectors | Cheaper log storage at scale |
| Weakness | Ops at scale, cost for logs | Smaller community now | Scale ceiling | Relevance features, scale | Complexity | Less full-text flexibility |

OpenSearch is the Apache-licensed fork (2021) after Elastic's license change; Elastic later re-added an open-source (AGPL) option in 2024. Mostly API-compatible for core features.

## 11. Interview questions

1. **Why is ES near-real-time and not real-time?** New documents become searchable only after a refresh creates a new segment (1 s default). Get-by-ID is real-time.
2. **What's the translog for?** Durability between Lucene commits; replayed on recovery.
3. **How do you choose the shard count?** Target 10–50 GB per shard from projected size; enough primaries for indexing parallelism; rollover for time-series; avoid oversharding.
4. **How do you change a mapping?** Create a new index with the new mapping, reindex (from source or `_reindex`), and atomically switch the alias.
5. **Why is deep pagination slow, and what's the fix?** Each shard must return from+size hits for merging. Use `search_after` with a PIT.
6. **How do you keep ES consistent with Postgres?** CDC via Kafka keyed by PK, external versioning to drop stale updates, a full-rebuild path, and drift checks.
7. **Can ES lose acknowledged writes?** With default settings it's quite durable (translog fsync per request, all in-sync copies). Risks: `translog.durability=async`, losing all copies of a shard, or historic split brain (pre-7.0). It's still not a primary store.
8. **`text` vs `keyword`?** `text` is analyzed (tokenized) for full-text search; `keyword` is exact for filtering, sorting, and aggregations. Often you map both (multi-fields).
9. **How does ES handle concurrent updates to a document?** Optimistic concurrency with `_seq_no` + `_primary_term` (409 on conflict), or external versions.
10. **How would you scale search QPS vs indexing throughput?** QPS: more replicas, caching, fewer shards per query (routing). Indexing: more primaries/nodes, bulk requests, longer refresh interval, fewer replicas during backfill.
