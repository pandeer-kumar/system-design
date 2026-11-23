# Databases: Choosing and Understanding Them

## Decision framework: start from access patterns

1. What are the **queries**? (point lookup, range, joins, full-text, graph traversal, aggregation)
2. What's the **read/write ratio** and **QPS**?
3. What **consistency and transactions** do you need?
4. What's the **data size** and growth?
5. What's the **latency target**?
6. What does the team know how to operate?

## Database categories

| Type | Examples | Strengths | Weaknesses | Use for |
|---|---|---|---|---|
| **Relational (OLTP)** | PostgreSQL, MySQL, Aurora | ACID, joins, constraints, mature | Horizontal write scaling needs sharding | Default for most transactional data |
| **Distributed SQL (NewSQL)** | Spanner, CockroachDB, YugabyteDB, TiDB, Aurora DSQL | SQL + horizontal scale + strong consistency | Higher write latency, cost, complexity | Global transactional systems |
| **Key-value** | DynamoDB, Redis, Riak, FoundationDB | Simple, fast, scalable | Limited queries | Sessions, carts, metadata, caching |
| **Wide-column** | Cassandra, ScyllaDB, HBase, Bigtable | Massive write throughput, scale | Query-driven modeling, limited transactions | Time series, messaging, feeds, IoT |
| **Document** | MongoDB, Couchbase, Firestore | Flexible schema, nested data | Joins limited; denormalization | Content, catalogs, user profiles |
| **Search** | Elasticsearch, OpenSearch, Solr | Full-text, fuzzy, faceting | Not a primary store; eventual | Search, log analytics |
| **Time-series** | Prometheus, InfluxDB, TimescaleDB, M3, Druid | Compression, time-window queries | Narrow use | Metrics, monitoring |
| **Graph** | Neo4j, Neptune, TAO (Meta) | Traversals | Scaling, niche | Social graphs, fraud detection, recommendations |
| **Columnar OLAP** | BigQuery, Snowflake, ClickHouse, Redshift, Druid, Pinot | Fast analytics over billions of rows | Not for point updates | Analytics, dashboards |
| **Vector** | pgvector, Pinecone, Milvus, FAISS | ANN similarity search | Newer | Embeddings, semantic search, RAG |

**Senior default:** "Postgres until proven otherwise." It handles JSON, full-text (basic), geospatial (PostGIS), vectors (pgvector), queues (`SKIP LOCKED`), and scales vertically a long way. Reach for specialized stores when a specific access pattern or scale demands it.

## Storage engines: B-Tree vs LSM-Tree (know internals)

### B-Tree (Postgres, MySQL InnoDB, most RDBMS)

- Balanced tree of fixed-size pages (4–16 KB); updates in place.
- **Writes:** find the page, modify it, write the WAL first for crash safety. Page splits on overflow.
- ✅ Fast reads (O(log n), typically 3–4 levels), predictable latency, good for read-heavy loads.
- ❌ Random writes, **write amplification** (writing a whole page for a small change, plus WAL), fragmentation.

### LSM-Tree (Cassandra, RocksDB, LevelDB, HBase, ScyllaDB, Bigtable)
```
Write → WAL (sequential) + MemTable (in-memory sorted)
      → when full: flush to immutable SSTable (L0)
      → background compaction merges SSTables into larger levels
Read  → MemTable → L0 SSTables → L1 → ... (Bloom filters skip SSTables)
```

- ✅ **Very high write throughput** (sequential I/O only), good compression.
- ❌ Reads may check multiple SSTables (read amplification); Bloom filters help point lookups but not ranges.
- ❌ **Compaction** uses CPU and I/O, and causes latency spikes; space amplification.
- **Compaction strategies:**
    - **Size-tiered (STCS):** merge similar-size tables. Write-optimized, high space amplification.
    - **Leveled (LCS):** non-overlapping levels. Read-optimized, more write amplification.
    - **Time-window (TWCS):** for time-series with TTL; drops whole expired files.
- **Deletes are tombstones.** Too many tombstones make reads slow (a Cassandra classic: queue-like workloads on Cassandra are an anti-pattern).

| | B-Tree | LSM |
|---|---|---|
| Write throughput | Moderate | High |
| Read latency | Low, predictable | Higher, variable (compaction) |
| Space | Fragmentation | Compression good; temp space for compaction |
| Best for | Read-heavy OLTP | Write-heavy, time series, logs |

**RUM conjecture:** you can optimize two of Read, Update, and Memory/space overhead, at the cost of the third.

## Indexes

- **Primary/clustered index:** data stored in index order (InnoDB clusters by PK; **a random UUID PK causes page splits and poor locality**, so prefer time-ordered IDs like UUIDv7 or Snowflake).
- **Secondary index:** extra structure pointing to rows; **every index slows writes**.
- **Composite index** `(a, b, c)`: the leftmost-prefix rule; supports `a`, `a,b`, `a,b,c` but not just `b`.
- **Covering index:** includes all the columns a query needs (index-only scan).
- **Partial index:** `WHERE status = 'active'`.
- **Specialized:** GIN (full-text, JSONB), GiST (geospatial, ranges), BRIN (huge append-only tables), hash.

## Write-Ahead Log (WAL)

- Every change is written to an append-only log **before** modifying data pages. On crash, replay the WAL.
- **fsync** makes it durable. Group commit batches multiple transactions' fsyncs.
- The WAL also feeds **replication** and **CDC**.
- `synchronous_commit=off` (Postgres) gives faster commits but risks losing the last ~few hundred ms on crash.

## Scaling a relational DB (the progression)

1. **Optimize:** indexes, query tuning, connection pooling (PgBouncer), avoiding N+1 queries.
2. **Vertical scale.**
3. **Caching** in front.
4. **Read replicas** for read scaling (handle replication lag).
5. **Functional partitioning:** separate DBs per domain/service.
6. **Sharding** (horizontal): by tenant/user/entity ID. Tools: Vitess (MySQL, used by YouTube and Slack), Citus (Postgres), application-level sharding.
7. **Move to distributed SQL** or NoSQL for specific workloads.

### Sharding pain points

- Cross-shard joins and transactions
- Resharding (use many logical shards mapped to fewer physical nodes)
- Global unique constraints
- Hot shards
- Schema migrations across N shards
- Operational overhead (backups, failover × N)

## NoSQL data modeling (DynamoDB/Cassandra)

**Model around queries, not entities.** Denormalize. Often one table per query pattern (Cassandra), or **single-table design** (DynamoDB) with overloaded keys:

```
PK              SK                    Attributes
USER#42         PROFILE               name, email
USER#42         ORDER#2024-01-05#9    total, status
USER#42         ORDER#2024-02-11#12   ...
ORDER#9         ITEM#1                sku, qty
```

- "Get user + recent orders" = one Query on `PK=USER#42`.
- GSIs for alternative access patterns (eventually consistent).

## Schema migrations without downtime (senior topic)

**Expand → migrate → contract:**

1. Add the new column/table (nullable, no default rewrite)
2. Dual-write to old and new
3. Backfill in batches (throttled)
4. Switch reads to new
5. Stop writing old
6. Drop old

Tools: gh-ost and pt-online-schema-change (MySQL), `CREATE INDEX CONCURRENTLY` (Postgres). Never take long table locks on hot tables.

## Choosing: quick reference

| Requirement | Pick |
|---|---|
| Transactions, joins, moderate scale | PostgreSQL/MySQL |
| Global, strongly consistent transactions | Spanner / CockroachDB |
| Massive write throughput, simple queries by key, time-ordered | Cassandra / ScyllaDB / Bigtable |
| Serverless, predictable single-digit ms at any scale, key-based | DynamoDB |
| Flexible documents | MongoDB / Firestore |
| Full-text search | Elasticsearch / OpenSearch |
| Analytics | ClickHouse / BigQuery / Snowflake / Druid / Pinot |
| Cache, counters, leaderboards, rate limits | Redis |
| Social graph at scale | Sharded MySQL + graph cache (Meta TAO) |
| Blob/large files | S3 / GCS (metadata in a DB) |
