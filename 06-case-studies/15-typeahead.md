# Case Study 15: Typeahead / Search Autocomplete

> Tests: latency budgets (< 100ms end to end), precomputation vs on-the-fly computation, tries, data pipelines for popularity, and caching at the edge.

## 1. Requirements

**Functional**
- As the user types a prefix, return the top 5–10 suggestions
- Ranked by popularity (and optionally personalization, freshness, locale)
- Handle trending queries (news events) within minutes

**Non-functional**
- **Latency: < 50ms server time, < 100ms perceived**
- Scale: 10B searches/day, ~5 keystroke requests per search → ~500K QPS peak
- Highly available; slightly stale suggestions OK

## 2. Key insight: precompute everything

The set of prefixes is bounded (most queries are short), and the top-K per prefix changes slowly. **Precompute `prefix → top-K suggestions`** offline and serve it with a lookup. Don't traverse a trie at query time if you can avoid it.

## 3. Data structures

### Trie with top-K cached at each node
```
root → "c" → "ca" → "car" [top: "car insurance", "cars for sale", "carmax", ...]
```
- Each node stores the top-K completions of its subtree, so lookup is O(prefix length).
- Memory: large for billions of queries. Prune rare queries (keep queries above a frequency threshold).

### Flat prefix → top-K map (simpler and more scalable)
```
"c"   → [...]
"ca"  → [...]
"car" → [...]
```
Store in a KV store (Redis, or in-memory sharded servers). Limit prefix length (e.g., up to 20 characters).

## 4. Data pipeline

```
Search logs → Kafka → aggregation
   Batch (daily/hourly, Spark): count query frequencies over a time-decayed window → filter (spam, unsafe, PII)
        → build prefix→top-K → versioned snapshot → load into serving nodes (blue/green swap)
   Streaming (Flink): trending queries in the last ~10 min (spikes vs baseline) → merged at serving time
```
- **Time decay:** `score = Σ count × e^(−λ·age)`, so old popular queries fade.
- **Filtering:** remove offensive, legally sensitive, or personal queries (a policy requirement for real products).

## 5. Serving architecture

```
Browser (debounce ~50–100ms, client cache of prefix results)
   → CDN/edge (cache popular prefixes, TTL minutes)
   → Typeahead service (sharded in-memory prefix maps, replicated)
   → merge: base suggestions + trending + personalized (user's own history) → rank → return
```
- **Sharding:** by prefix (first 1–2 characters), but distribution is skewed ("s" ≫ "x"). Use **hash of the full prefix**, or range splits tuned by load.
- **Replication** for read throughput; all data is read-only between rebuilds, so it's trivially consistent.
- **Client-side optimizations:** debounce keystrokes, cancel in-flight requests when the user types more, cache results per prefix, prefetch next-character results.

## 6. Personalization

- The user's recent searches (stored per user, small) merged with the global suggestions at request time.
- Locale/region-specific maps (separate builds per language/region).

## 7. Updating without downtime

- Build the new snapshot offline → load it onto a new set of serving nodes, or atomically swap the in-memory structure (double buffering) → shift traffic.
- Trending updates go through a smaller real-time overlay store.

## 8. Failure modes and edge cases

| Case | Handling |
|---|---|
| Serving node down | Replicas; the client tolerates failure (no suggestions is fine) |
| Bad data (offensive suggestion) | Blocklist applied at serving time with fast propagation (minutes) |
| Spammers gaming suggestions | Count unique users, not raw queries; anomaly detection |
| Very long prefix | No precomputed entry → fall back to the top-K of the longest stored prefix filtered by the full prefix, or return none |

## 9. Follow-ups

- **Fuzzy matching / typos:** edit-distance tolerant lookups (precompute common misspellings, or use a finite-state transducer such as Lucene's FST suggester).
- **Why not Elasticsearch completion suggester?** It works for moderate scale; at very high QPS a custom precomputed in-memory service is cheaper and faster.
