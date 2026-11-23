# Papers Every Senior Engineer Should Know (Summarized)

For each paper: what problem it solved, the key ideas, and **what to say in interviews**. Reading the originals is worth it for the top 10.

---

## Tier 1: must know

### 1. Dynamo: Amazon's Highly Available Key-value Store (2007)
- **Problem:** the shopping cart must always accept writes, even during failures.
- **Ideas:** consistent hashing + vnodes, sloppy quorums + hinted handoff, vector clocks for versioning, read-time conflict resolution by the app, Merkle-tree anti-entropy, gossip membership.
- **Lesson:** availability over consistency, with conflicts pushed to the application. Influenced Cassandra, Riak, and Voldemort. (DynamoDB the product is a different design: leader-based Multi-Paxos per partition.)
- **Interview:** the reference design for the KV store question ([case study](../06-case-studies/03-key-value-store.md)).

### 2. Google File System (2003)
- **Problem:** store huge files on commodity hardware that fails constantly.
- **Ideas:** single master for metadata (in memory), 64 MB chunks replicated 3× on chunk servers, the master is off the data path, leases to primary replicas to order mutations, record append, relaxed consistency.
- **Lesson:** separate metadata from data; design for failure as the norm. HDFS cloned it.

### 3. MapReduce (2004)
- **Ideas:** a map/shuffle/reduce programming model; the framework handles distribution, fault tolerance (re-execution), locality, and stragglers (backup tasks).
- **Lesson:** deterministic tasks over durable inputs make fault tolerance trivial (just re-run). Spark generalized this.

### 4. Bigtable (2006)
- **Ideas:** sparse sorted map `(row, column, timestamp) → value`; tablets (range partitions) that split; LSM storage (memtable + SSTables on GFS); Chubby for the master lock and metadata; Bloom filters.
- **Lesson:** range partitioning with dynamic splits + LSM trees. HBase and Cassandra's storage engine descend from it.

### 5. Spanner (2012)
- **Problem:** globally distributed, strongly consistent SQL.
- **Ideas:** Paxos groups per split; 2PC across groups for transactions; **TrueTime** (GPS + atomic clocks, bounded uncertainty ε) + **commit wait** → external consistency (strict serializability); lock-free snapshot reads at timestamps.
- **Lesson:** you can have global strong consistency if you pay in latency (commit wait plus cross-region Paxos) and invest in clock infrastructure.

### 6. Raft: In Search of an Understandable Consensus Algorithm (2014)
- **Ideas:** leader election with randomized timeouts, log replication, safety via the election restriction, terms as logical clocks, membership changes.
- **Lesson:** the consensus algorithm behind etcd, Consul, CockroachDB, TiKV, and Kafka KRaft. Know it in detail ([chapter](../03-distributed-systems/06-consensus.md)).

### 7. Kafka: a Distributed Messaging System for Log Processing (2011) + "The Log" (Jay Kreps, 2013 blog)
- **Ideas:** a partitioned, replicated, append-only log; consumers pull and track offsets; sequential I/O + page cache + zero-copy; the log as the unifying abstraction for data integration.
- **Lesson:** a log is the source of truth, and everything else (DBs, caches, indexes) is a derived view.

### 8. Scaling Memcache at Facebook (2013)
- **Ideas:** look-aside caching; **leases** to fix stale sets and thundering herds; **mcrouter**; gutter pools for failures; regional pools; invalidation via MySQL binlog (McSqueal); remote markers for cross-region read-your-writes; cold cluster warm-up.
- **Lesson:** the cache consistency and operations playbook at scale ([case study](../06-case-studies/22-distributed-cache.md)).

### 9. The Tail at Scale (Dean & Barroso, 2013)
- **Ideas:** with fan-out, rare slowness becomes common. Techniques: **hedged requests**, tied requests, micro-partitioning, selective replication of hot items, latency-induced probation, good-enough (partial) results, canary requests.
- **Lesson:** design for p99, not the average.

### 10. Chubby Lock Service (2006)
- **Ideas:** coarse-grained locks + small file storage via Paxos; sessions and KeepAlives; **sequencers** (fencing tokens); client caching with invalidation.
- **Lesson:** a lock service is used mostly for leader election and metadata. ZooKeeper was inspired by it.

---

## Tier 2: strongly recommended

| Paper | Key idea | Takeaway |
|---|---|---|
| **ZooKeeper (2010)** | Wait-free coordination kernel; znodes, watches, ephemeral/sequential nodes; ZAB | Build locks, elections, and config on primitives; linearizable writes, sequentially consistent reads |
| **Cassandra (2009)** | Dynamo distribution + Bigtable data model | Wide-column, tunable consistency |
| **Time, Clocks, and the Ordering of Events (Lamport, 1978)** | Happened-before, logical clocks, total ordering | The foundation of reasoning about distributed time |
| **Paxos Made Simple (Lamport, 2001)** | Single-decree Paxos explained | Prepare/promise/accept/accepted; quorum intersection |
| **FLP impossibility (1985)** | No deterministic consensus in async systems with one faulty process | Liveness needs timing assumptions |
| **CAP proof (Gilbert & Lynch, 2002)** | Formalizes Brewer's conjecture | Linearizability vs availability under partition |
| **Harvest, Yield, and Scalable Tolerant Systems (Fox & Brewer, 1999)** | Degrade harvest (completeness) to keep yield (availability) | Graceful degradation, partial results |
| **Amazon Aurora (2017)** | "The log is the database": compute ships only redo logs to a 6-way replicated storage layer (quorum 4/6 writes, 3/6 reads) across 3 AZs | Separating compute and storage; quorum storage |
| **TAO: Facebook's Distributed Data Store for the Social Graph (2013)** | Objects + associations over sharded MySQL with a write-through, read-mostly cache tier, leader/follower caches | Graph at scale on a relational DB |
| **Borg / Omega / Kubernetes (2015–16)** | Cluster management; declarative desired state + reconciliation loops | Control loops as an architecture pattern |
| **Zanzibar: Google's Consistent, Global Authorization System (2019)** | Relationship tuples, zookies for snapshot consistency, Leopard index | ReBAC at scale |
| **Gorilla: Facebook's in-memory TSDB (2015)** | Delta-of-delta timestamps, XOR float compression | Time-series compression |
| **Monarch (Google, 2020)** | Planet-scale in-memory time series, regional + global query | Metrics at extreme scale |
| **F1 / Megastore** | SQL on Spanner; earlier entity-group Paxos | Evolution toward Spanner |
| **Dapper (Google, 2010)** | Distributed tracing with low-overhead sampling | Foundation of Zipkin, Jaeger, OpenTelemetry |
| **Photon (Google, 2013)** | Exactly-once joining of continuous streams across data centers using a Paxos-based ID registry | Exactly-once stream joins |
| **MillWheel / Dataflow Model (2013/2015)** | Watermarks, event time, windowing, triggers | Foundation of Beam/Flink semantics |
| **Calvin (2012)** | Deterministic database: sequence transactions first, then execute deterministically | Avoid 2PC with determinism (FaunaDB) |
| **CRDTs (Shapiro et al., 2011)** | Convergent and commutative replicated data types | Strong eventual consistency |
| **Bitcoin (2008)** | Proof-of-work Byzantine consensus | Awareness level |

---

## Tier 3: practitioner essays and articles

- **"Designing Data-Intensive Applications"** (Kleppmann): **read this book.** Almost everything here is covered in depth.
- **"How to do distributed locking"** (Kleppmann, 2016): the Redlock critique; fencing tokens.
- **"Notes on Distributed Systems for Young Bloods"** (Jeff Hodges): practical wisdom.
- **"The Network is Reliable"** (Bailis & Kingsbury, 2014): partitions happen; real evidence.
- **Jepsen analyses** (Kyle Kingsbury): real databases violating their claimed guarantees. Read a few (MongoDB, etcd, Redis, CockroachDB).
- **AWS Builders' Library:** timeouts/retries/backoff with jitter, static stability, shuffle sharding, avoiding insurmountable queue backlogs, leader election, caching challenges. **Excellent and interview-relevant.**
- **Google SRE Book:** chapters on handling overload, cascading failures, load balancing, distributed consensus.
- **"On Designing and Deploying Internet-Scale Services"** (James Hamilton, 2007): operations-friendly design checklist.
- **"Metastable Failures in Distributed Systems"** (Bronson et al., 2021).
- **"Fallacies of Distributed Computing Explained"** (Rotem-Gal-Oz).
- **Uber, Netflix, Discord, Slack, Stripe, Figma engineering blogs:** real case studies (see [03-company-architectures.md](03-company-architectures.md)).
