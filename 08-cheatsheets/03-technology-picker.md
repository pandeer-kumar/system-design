# Technology Picker

Name the requirement first, then the technology. "I need X, so Y."

| Requirement | Default pick | Alternatives | Why |
|---|---|---|---|
| Transactional business data | **PostgreSQL** | MySQL, Aurora | ACID, mature, flexible |
| Global strongly consistent SQL | **Spanner** | CockroachDB, YugabyteDB, Aurora DSQL | Distributed transactions across regions |
| Massive write throughput, key-based access | **Cassandra / ScyllaDB** | Bigtable, HBase | LSM, linear scaling |
| Serverless KV at any scale | **DynamoDB** | Bigtable, Cosmos DB | Managed, predictable latency |
| Flexible documents | **MongoDB** | Firestore, Couchbase | Schema flexibility |
| Cache | **Redis** | Memcached, Dragonfly, KeyDB | Data structures, atomic ops |
| Leaderboard / ranking | **Redis sorted sets** | | O(log n) rank |
| Rate limiting counters | **Redis + Lua** | Envoy RLS | Atomic, fast |
| Event streaming / CDC backbone | **Kafka** | Kinesis, Pulsar, Redpanda | Replayable partitioned log |
| Job/task queue | **SQS** | RabbitMQ, Redis Streams, Postgres `SKIP LOCKED` | Per-message ack, DLQ, visibility timeout |
| Workflow orchestration (sagas, long-running) | **Temporal** | Step Functions, Cadence, Conductor | Durable execution |
| Coordination, leader election, config | **etcd** | ZooKeeper, Consul | Raft, linearizable, leases |
| Full-text search | **Elasticsearch / OpenSearch** | Solr, Typesense, Meilisearch | Inverted index |
| Vector / semantic search | **pgvector** (small–mid) | Pinecone, Milvus, Weaviate, FAISS | ANN (HNSW) |
| Blob/object storage | **S3** | GCS, Azure Blob, MinIO | Durable, cheap, scalable |
| CDN | **CloudFront / Cloudflare / Akamai / Fastly** | | Edge caching |
| Real-time analytics (user-facing) | **Pinot / Druid / ClickHouse** | | Sub-second OLAP on fresh data |
| Data warehouse | **BigQuery / Snowflake** | Redshift, Databricks | SQL analytics at scale |
| Stream processing | **Flink** | Kafka Streams, Spark Streaming, Dataflow | Stateful, exactly-once |
| Batch processing | **Spark** | Dataflow, Hadoop | Distributed compute |
| Data lake tables | **Iceberg** | Delta Lake, Hudi | ACID on object storage |
| Time-series metrics | **Prometheus (+ Mimir/Thanos)** | M3, InfluxDB, TimescaleDB, Datadog | Compression, PromQL |
| Logs | **OpenSearch / Loki** | Splunk, ClickHouse | |
| Tracing | **OpenTelemetry + Jaeger/Tempo** | Zipkin, X-Ray | |
| Graph queries | **Neo4j / Neptune** | Sharded SQL + cache (TAO-style) | Traversals |
| Geospatial | **PostGIS / Redis GEO / H3 / S2** | Elasticsearch geo | Spatial indexes |
| L7 proxy / service mesh | **Envoy** (Istio) | Nginx, HAProxy, Linkerd | Rich routing, observability |
| API gateway | **Kong / AWS API Gateway / Envoy** | Apigee | Auth, rate limiting |
| Push notifications | **APNs / FCM** | | Platform requirement |
| Container orchestration | **Kubernetes** | ECS, Nomad | |
| Unique IDs | **Snowflake / UUIDv7** | Segment allocation | Sortable, no coordination |
| Authorization (ReBAC) | **SpiceDB / OpenFGA** | Custom | Zanzibar model |
| Secrets | **Vault / AWS Secrets Manager** | | |
| Feature flags | **LaunchDarkly / Unleash** | | Decouple deploy from release |

## Red flags to avoid

- A **queue on Cassandra** (tombstones)
- **Kafka as a database** for random point lookups
- **Elasticsearch as the primary source of truth**
- **Redis as the durable system of record** without understanding async replication loss
- **ZooKeeper/etcd for high-volume data** (they're for metadata; etcd's recommended DB size is ~8 GB)
- **2PC across microservices**
- **Wall-clock timestamps for ordering** across machines
- **Microservices for a 3-person team**
