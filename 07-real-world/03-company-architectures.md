# How Big Companies Actually Built It

Short summaries of well-known public architectures. They give you concrete references ("Instagram generates IDs inside Postgres...") that make answers credible. Details change over time; this captures the widely documented designs.

## Twitter / X
- **Timeline:** fan-out on write into Redis-based timeline caches (lists of tweet IDs); celebrities handled with fan-out on read and merged at query time.
- **IDs:** Snowflake (64-bit time-ordered).
- **Storage:** Manhattan (in-house distributed KV); MySQL historically; Earlybird (Lucene-based real-time search).
- **Lesson:** the hybrid fan-out model.

## Instagram
- Started on Django + **PostgreSQL**, sharded logically (thousands of logical shards mapped to fewer physical servers).
- **IDs generated in Postgres** via PL/pgSQL: 41-bit time + 13-bit logical shard ID + 10-bit sequence.
- Cassandra for some feeds/inbox data; heavy memcached use.
- **Lesson:** simple tech, logical shards for easy resharding.

## Facebook / Meta
- **TAO:** a graph data model (objects + associations) over sharded MySQL with a massive caching tier.
- **Memcache** at enormous scale (leases, mcrouter, McSqueal invalidation).
- **News Feed:** largely pull-based aggregation with ranking over candidates held in memory (multifeed).
- Storage: Haystack (photos: fewer disk seeks by packing photos into large files with an in-memory index), f4 (warm blob storage with erasure coding).
- **Lesson:** read-optimized caching, cache consistency engineering.

## Netflix
- **AWS-native microservices**; Zuul (edge gateway), Eureka (AP service discovery), Hystrix (circuit breakers, now retired), Chaos Monkey / Simian Army.
- **Open Connect CDN** inside ISPs with pre-positioned content.
- Cassandra (multi-region), EVCache (memcached-based), Kafka, Flink.
- Regional evacuation: regularly fail an entire AWS region over.
- **Lesson:** chaos engineering, resilience patterns, and owning the CDN for the dominant cost.

## Uber
- Moved from a monolith to thousands of microservices (and later consolidated into "domain-oriented" groupings).
- **Ringpop** (consistent hashing + SWIM gossip) for sharding stateful services such as dispatch.
- **Schemaless** (on MySQL) → Docstore; Cassandra; H3 hex grid.
- **Cadence** (workflow engine) → **Temporal** spun out.
- Kafka at massive scale; Apache Hudi (incremental data lake); M3 (metrics).
- **Lesson:** geo-partitioned dispatch, workflow engines for business processes.

## Amazon
- Service-oriented since the early 2000s ("two-pizza teams", APIs only).
- **Dynamo** → DynamoDB; **cell-based architecture** and **shuffle sharding**; static stability.
- **Aurora:** log-structured, quorum-replicated storage.
- **Lesson:** blast-radius reduction as a first-class design goal.

## Google
- GFS → Colossus; Bigtable; **Spanner**; Borg; Chubby; MapReduce → Flume/Dataflow; Monarch; Zanzibar; Maglev (L4 LB).
- **Lesson:** strong consistency via infrastructure investment (TrueTime), and SRE practices.

## LinkedIn
- Created **Kafka**; Espresso (document store), Voldemort (Dynamo-like KV); Pinot (real-time OLAP); Samza.
- **Lesson:** the log as the integration backbone.

## WhatsApp
- **Erlang/FreeBSD**, ~2M connections per server; tiny engineering team for hundreds of millions of users.
- Store-and-forward with E2E encryption (Signal protocol); messages deleted from servers after delivery.
- **Lesson:** the right runtime (actor model) for massive concurrency.

## Discord
- Elixir (Erlang VM) for real-time gateways and guild processes; Rust for performance-critical services.
- Messages: MongoDB → Cassandra → **ScyllaDB**, with Rust "data services" for request coalescing.
- **Lesson:** hot partitions and request coalescing.

## Slack
- PHP/Hack monolith + Vitess (sharded MySQL); channel servers (consistent hashing) for real-time messaging; gateway servers per region.
- Moved toward a **cellular architecture** after incidents.
- **Lesson:** sharding migrations (to Vitess) at scale, cell isolation.

## Stripe
- Idempotency keys as a public API contract; Ruby monolith with heavy investment in tooling; MongoDB (with their own sharding layer, DocDB) at scale; a double-entry ledger system.
- **Lesson:** API-level idempotency and correctness culture.

## Figma
- Multiplayer: a server-authoritative design where each document is handled by one process; LWW per property for the object tree (CRDT-inspired); a Rust multiplayer server.
- Postgres scaled with vertical partitioning, then horizontal sharding.
- **Lesson:** a single owner per document; simple conflict semantics fit for the domain.

## Shopify
- Modular monolith (Rails) with **pods** (isolated shards containing a subset of shops, each with its own MySQL, Redis, etc.); flash sale handling.
- **Lesson:** a modular monolith at massive scale; pod/cell isolation for noisy tenants.

## YouTube
- MySQL scaled with **Vitess** (created at YouTube); Bigtable; custom video transcoding ASICs (Argos VCU); the Google global CDN.

## Dropbox
- Moved off S3 to its own storage (**Magic Pocket**) for cost; Edgestore metadata; Rust sync engine rewrite ("Nucleus") for correctness.
- **Lesson:** at large scale, owning infrastructure for the dominant cost can pay off.
