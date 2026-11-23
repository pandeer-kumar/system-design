# Search and Indexing

> **Go deeper:** [Elasticsearch internals](../09-technology-deep-dives/06-elasticsearch.md)

## Inverted index

Maps **term → posting list** (document IDs where the term appears, often with positions and frequencies).

```
"distributed" → [doc1, doc4, doc9]
"systems"     → [doc1, doc2, doc9]
Query "distributed systems" → intersect → [doc1, doc9]
```

### Indexing pipeline
```
Document → tokenize → normalize (lowercase, strip accents) → stop words → stem/lemmatize ("running" → "run") → synonyms → index
```

### Ranking

- **TF-IDF:** term frequency × inverse document frequency.
- **BM25:** the modern default (Elasticsearch/Lucene). TF saturation plus document length normalization.
- **Learning to rank / ML re-ranking:** a two-phase approach. Cheap retrieval (BM25 or ANN) for the top ~1,000 candidates, then an expensive ML model re-ranks the top N.
- **Signals:** freshness, popularity, personalization, click-through rate.

### Posting list optimizations

- Sorted doc IDs with **delta encoding + variable-byte / PForDelta compression**
- **Skip lists** for fast intersection
- Tiered indexes: a small "hot" tier of high-quality docs searched first

## Lucene / Elasticsearch internals

- Index = many immutable **segments** (like LSM SSTables). New docs go to an in-memory buffer, then a new segment is created on **refresh** (default 1s), which is why ES is **near-real-time**.
- **Merges** combine segments in the background.
- Deletes are marked (bitset) and removed on merge.
- **Translog** (WAL) for durability between Lucene commits (flush).
- **Index → shards (primary + replicas).** The primary shard count is fixed at creation (resizing needs split/shrink/reindex).
- **Query = scatter-gather:** the coordinating node sends the query to one copy of each shard, gets the top-K from each, merges, then fetches the docs.
- **Deep pagination is expensive** (`from + size` on every shard). Use `search_after`.

## Sharding search indexes

| Strategy | How | Pros | Cons |
|---|---|---|---|
| **Document-partitioned** | Each shard holds a subset of docs, full index for them | Writes go to one shard; easy to scale | Every query hits every shard (scatter-gather; tail latency) |
| **Term-partitioned** | Each shard holds posting lists for a subset of terms | Query touches only shards for its terms | Multi-term queries cross shards; writes touch many shards; hot terms |

**Almost everyone uses document partitioning**, with replicas for query throughput.

**Tail latency in scatter-gather:** with 100 shards, the query is as slow as the slowest shard. Mitigations: replicas + hedged requests, partial results after a timeout, fewer bigger shards.

## Keeping search in sync with the primary DB

**Never dual-write** (app writes DB then ES): it diverges on failure.

**Use CDC:** DB → Debezium → Kafka → indexer → Elasticsearch.

- Idempotent indexing using the doc ID and **external version** (DB version/LSN) so out-of-order updates don't overwrite newer data: `PUT /idx/_doc/42?version=17&version_type=external`.
- Periodic **full reindex** into a new index with an alias swap for schema changes or drift repair.

## Search at scale: typical architecture

```
Writes:  Primary DB → CDC → Kafka → Indexers → Search cluster (sharded, replicated)
Queries: Client → Search API → query understanding (spell, synonyms, intent)
         → retrieval (BM25 + vector ANN) → ranking (ML) → results (cached for popular queries)
```

## Vector search (semantic search, RAG)

- Text, images, and more become **embeddings** (dense vectors). Find nearest neighbours by cosine or dot-product similarity.
- **ANN (approximate nearest neighbour) indexes:**
    - **HNSW** (hierarchical navigable small world graph): high recall, fast, memory-heavy. The default in most vector DBs and pgvector.
    - **IVF** (inverted file with clustering) + **PQ** (product quantization) to compress vectors: FAISS, for billion scale.
    - **ScaNN** (Google), **DiskANN** (SSD-resident).
- **Hybrid search:** BM25 + vector scores combined (reciprocal rank fusion) usually beats either alone.
- Filtering + ANN is tricky (pre-filter vs post-filter trade-offs).

## Typeahead is different

Prefix search with very tight latency: tries or precomputed prefix → top-K maps. See [06-case-studies/15-typeahead.md](../06-case-studies/15-typeahead.md).
