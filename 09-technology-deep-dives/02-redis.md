# Redis Internals: A Deep Dive

> Redis appears in almost every design (cache, rate limiter, lock, leaderboard, session store, queue). Strong candidates know **why** it's fast, **what** it guarantees (and doesn't), and **how** it fails. Note: after Redis changed its license in 2024, the Linux Foundation fork **Valkey** became the default in many clouds (ElastiCache, MemoryDB). Redis 8 (2025) added an AGPL option. Everything below applies to both unless noted.

## 1. Architecture: why a single thread is fast

```
clients ──TCP──> event loop (epoll/kqueue) ──> parse command ──> execute against in-memory dataset ──> reply
                 one main thread executes ALL commands, one at a time
```

- Commands touch memory only (≈ µs), so the bottleneck is **network I/O and syscalls**, not CPU.
- **Single-threaded execution means every command is atomic**, with no locks and no context switches. `INCR`, `SET NX`, `LPUSH`, and Lua scripts can't interleave with other commands.
- **I/O threads** (Redis 6+, `io-threads`) parallelize socket reads/writes and protocol parsing; execution stays single-threaded. Valkey 8 went further with async I/O threading.
- **Background threads** handle slow cleanup: `UNLINK`/`FLUSHALL ASYNC` (lazy free), fsync of the AOF, closing files.
- Throughput: ~100K–200K ops/s per instance for simple commands without pipelining; **1M+ with pipelining**.

**Consequence:** one slow command blocks *everyone*. `KEYS *`, `SMEMBERS` on a 10M-element set, `DEL` of a huge key, or a long Lua script stalls the server. Use `SCAN`, `UNLINK`, and bounded scripts.

## 2. Data structures and their encodings

Redis picks compact encodings for small values and switches to general ones as they grow:

| Type | Small encoding | Large encoding | Notes |
|---|---|---|---|
| String | `int` (if numeric), `embstr` (≤44 bytes, one allocation) | `raw` SDS | SDS = length-prefixed, binary-safe string with O(1) length |
| List | `listpack` | `quicklist` (linked list of listpacks) | O(1) push/pop at ends; O(n) index |
| Hash | `listpack` (≤128 fields, ≤64-byte values by default) | `hashtable` | Small hashes are very memory-efficient: store objects as hashes |
| Set | `intset` (all ints) / `listpack` | `hashtable` | |
| Sorted set | `listpack` (≤128 entries) | **skiplist + hashtable** | Hashtable gives O(1) score lookup; skiplist gives O(log n) rank/range |
| Stream | Radix tree of listpacks | | Append-only log with consumer groups |
| HyperLogLog | Sparse / dense (12 KB) | | ~0.81% error |
| Bitmap / Bitfield | String | | `SETBIT`, `BITCOUNT` |
| Geo | Sorted set with geohash score | | `GEOSEARCH` |

### Why skiplists for sorted sets?
Ordered, O(log n) insert/delete/search like a balanced tree, but simpler, cache-friendly for range scans, and each node stores **span** counts so `ZRANK` is O(log n). Leaderboards depend on this.

### Incremental rehashing
The main dictionary (and large hashes) resize by keeping **two tables** and migrating a few buckets on each operation plus a background cron. That avoids a long pause when a table with millions of keys doubles.

## 3. Expiration and eviction

**Expiration (TTL):**

- **Lazy:** a key is checked on access; if expired, it's deleted then.
- **Active:** a periodic cycle samples random keys with TTLs and deletes expired ones, repeating while more than ~10% of the sample was expired (bounded CPU time).
- So expired keys can occupy memory briefly. On replicas, expiration is driven by the primary (it sends `DEL`s), and replicas hide logically expired keys on reads.

**Eviction when `maxmemory` is reached** (`maxmemory-policy`):

| Policy | Evicts |
|---|---|
| `noeviction` | Nothing; writes return errors (use for data stores, queues) |
| `allkeys-lru` | Approximately least-recently-used among all keys (common cache default) |
| `allkeys-lfu` | Least frequently used (with decay); better for skewed popularity |
| `volatile-lru` / `volatile-lfu` / `volatile-ttl` / `volatile-random` | Only keys with a TTL |
| `allkeys-random` | Random |

**Approximate LRU:** Redis doesn't keep a full LRU list (too much memory). It samples `maxmemory-samples` (5) keys, keeps an **eviction pool** of good candidates, and evicts the best. With 10 samples it's very close to true LRU.

**LFU:** a logarithmic 8-bit counter per key (probabilistic increment) plus decay over time.

## 4. Persistence

| | RDB (snapshot) | AOF (append-only file) |
|---|---|---|
| How | `fork()`; the child writes a point-in-time snapshot using **copy-on-write** pages | Every write command appended to a log |
| Durability | Lose everything since the last snapshot (minutes) | `appendfsync always` (every write, slow), **`everysec`** (lose ≤ ~1 s, the usual choice), `no` (OS decides) |
| Restart speed | Fast (load a compact binary) | Slower (replay), mitigated by RDB preamble |
| File size | Compact | Large; compacted by **AOF rewrite** (background fork) |

- Redis 7 uses **multi-part AOF**: a base file (RDB format) plus incremental AOF files, managed by a manifest.
- **The fork problem:** forking a 50 GB process copies page tables (tens to hundreds of ms of latency spike), and copy-on-write can **double memory** under heavy writes during the snapshot. Keep instances moderate in size (≤ 25–50 GB), disable Transparent Huge Pages, and leave memory headroom.
- **Pure cache?** Disable persistence entirely, or keep RDB only for faster warm restarts.

## 5. Replication

```
Primary ──(replication stream: every write command)──> Replica 1, Replica 2
```

- **Asynchronous by default.** The primary acknowledges the client **before** replicas receive the write.
- **Full sync:** the replica sends `PSYNC`; the primary forks, sends an RDB, then streams buffered writes.
- **Partial resync:** the primary keeps a **replication backlog** (ring buffer). A briefly disconnected replica resumes from its offset if it's still in the backlog; otherwise it does a full sync (expensive, so size the backlog generously).
- **Replication ID + offset** identify a dataset's history; after a failover, the new primary keeps the old ID as a secondary ID so other replicas can partially resync.
- **`WAIT numreplicas timeout`:** block until N replicas acknowledge the write. That **reduces** but does not eliminate loss: a failover can still promote a replica that missed it, and `WAIT` doesn't make Redis strongly consistent.
- **`min-replicas-to-write` / `min-replicas-max-lag`:** the primary refuses writes if fewer than N replicas are connected and recent. This limits the damage from a partitioned primary (split brain) to roughly the lag window.

**Bottom line for interviews:** standard Redis replication can **lose acknowledged writes on failover**. For a durable source of truth, use a product with a replicated transaction log (**AWS MemoryDB**, Redis Enterprise with AOF + replication tuning), or keep the truth in a database.

## 6. High availability: Sentinel

- A set of **Sentinel** processes (≥3, on separate hosts) monitor the primary and replicas.
- If a quorum of Sentinels think the primary is down (**ODOWN**), they elect a leader Sentinel (Raft-like vote with a **config epoch**), which promotes the best replica (lowest replica priority, then most replication offset).
- Clients ask Sentinels for the current primary address.
- Failover takes seconds; writes during that window fail; writes acked by the old primary but not yet replicated are lost.

## 7. Scaling out: Redis Cluster

- The key space is split into **16,384 hash slots**: `slot = CRC16(key) mod 16384`. Each primary owns a set of slots; each primary has replicas.
- **Hash tags:** only the part of the key inside `{...}` is hashed. `{user42}:cart` and `{user42}:profile` land in the same slot, so **multi-key operations and Lua scripts across them work**. Cross-slot multi-key operations are rejected (`CROSSSLOT`).
- **Client routing:** smart clients cache the slot → node map. A request to the wrong node gets `MOVED <slot> <node>` (update the map). During a slot migration, `ASK` redirects for keys already moved.
- **Cluster bus:** nodes gossip on a separate port (heartbeats, failure detection: PFAIL → FAIL when a majority of primaries agree).
- **Failover:** a replica of a failed primary is elected by the majority of primaries (with config epochs to resolve conflicts).
- **Consistency:** no strong consistency. A primary partitioned into the minority keeps accepting writes until `cluster-node-timeout`, and those writes are lost when a replica on the majority side is promoted.
- **Resharding:** move slots key by key (`MIGRATE`) while serving traffic. Big keys make migration slow.
- **Limits:** a practical cluster size of up to ~1,000 nodes; no cross-slot transactions; `SELECT` (multiple DBs) is unsupported.

**Alternatives for sharding:** a proxy (Twemproxy, Envoy Redis proxy) with client-agnostic routing, or client-side consistent hashing over standalone instances.

## 8. Atomicity tools

| Tool | Guarantees | Notes |
|---|---|---|
| Single command | Atomic | `INCR`, `SET key val NX PX 30000`, `LMOVE`, `ZADD GT` |
| `MULTI`/`EXEC` | Commands queued and run back-to-back without interleaving | **No rollback** if one command fails at runtime; can't branch on intermediate results |
| `WATCH` + `MULTI`/`EXEC` | Optimistic locking: `EXEC` aborts if a watched key changed | Retry loop under contention |
| **Lua scripts / Functions** | Whole script atomic; can read, branch, and write | Keep short (blocks the server); declare all keys (needed for Cluster); `FUNCTION` (Redis 7) persists scripts server-side |
| Pipelining | **Not atomic**; just batches round trips | Huge throughput win |

## 9. Pub/Sub vs Streams vs Lists (messaging in Redis)

| | Pub/Sub | Lists (`LPUSH`/`BRPOP`, `LMOVE`) | Streams (`XADD`, consumer groups) |
|---|---|---|---|
| Delivery | Fire-and-forget to **currently connected** subscribers | One consumer per message | Consumer groups, each message to one consumer in a group |
| Persistence | None (offline subscribers miss messages) | Yes (in memory + persistence) | Yes |
| Ack / redelivery | No | Manual (reliable queue pattern with `LMOVE` to a processing list) | **Yes**: Pending Entries List (PEL), `XACK`, `XAUTOCLAIM` to take over stuck messages |
| Replay | No | No | Yes, by ID |
| Use | Live notifications, cache invalidation broadcast, chat fan-out to online users | Simple job queues (Sidekiq, older Celery broker) | Lightweight event streams/queues, activity feeds |

**Sharded Pub/Sub** (Redis 7, `SPUBLISH`) scopes channels to slots, so Pub/Sub scales in Cluster mode instead of broadcasting to every node.

**Reliable queue with lists:**
```
LMOVE jobs processing:{worker} RIGHT LEFT   # atomically take a job and record it as in-progress
... process ...
LREM processing:{worker} 1 <job>            # ack
A reaper moves jobs from dead workers' processing lists back to `jobs`.
```

## 10. Common patterns (with the gotchas)

| Pattern | Implementation | Gotcha |
|---|---|---|
| Cache | `GET`/`SET key val EX ttl` | Stampedes, stale sets (see [caching](../04-building-blocks/02-caching.md)) |
| Distributed lock | `SET lock:x <uuid> NX PX 30000`; release with check-and-delete Lua | Not safe for correctness under failover/pauses; no fencing token ([locks](../02-concurrency/05-distributed-locks.md)) |
| Rate limiter | Lua token bucket or `INCR` + `EXPIRE` | Use server time; hot keys ([case study](../06-case-studies/02-rate-limiter.md)) |
| Leaderboard | Sorted set `ZINCRBY`, `ZREVRANK`, `ZREVRANGE` | One huge zset is a hot key; float precision of scores (53 bits) |
| Session store | Hash per session with TTL | Replication loss logs users out (acceptable) |
| Counters | `INCR`, `HINCRBY`; sharded keys for hot counters | Write-behind to a DB for durability |
| Unique counting | `PFADD`/`PFCOUNT` | Approximate |
| Dedup / idempotency | `SET dedup:{id} 1 NX EX 86400` | Lost on failover → rare duplicates |
| Delayed jobs | Sorted set scored by run time; poll `ZRANGEBYSCORE` + atomic claim via Lua/`ZPOPMIN` | Single key can get hot; shard by bucket |
| Geo search | `GEOADD`, `GEOSEARCH` | Per-city keys to bound size |
| Bloom filter | RedisBloom module (`BF.ADD`) | Module availability |
| Presence | `SET online:{user} 1 EX 60` refreshed by heartbeat | |

## 11. Production pitfalls

1. **Big keys:** a hash with 10M fields or a 500 MB string. They block on delete (use `UNLINK`), skew cluster memory, and slow migrations and replication. Find them with `redis-cli --bigkeys` / `--memkeys`. Split them.
2. **Hot keys:** one key saturates one shard's single thread. Find them with `--hotkeys` (LFU policy) or client-side sampling. Fix with local caching or key replication.
3. **O(N) commands in production:** `KEYS`, `FLUSHALL` (sync), `SMEMBERS`/`HGETALL` on huge collections, `LRANGE 0 -1`. Use `SCAN` family commands.
4. **Fork latency and memory doubling** during RDB/AOF rewrite.
5. **Memory fragmentation:** check `mem_fragmentation_ratio`; enable `activedefrag`.
6. **Connection storms:** thousands of clients reconnecting after a failover. Use pooling and jittered reconnects.
7. **No `maxmemory` set on a cache:** the OS OOM killer ends the process.
8. **Treating Redis as durable** without understanding async replication.
9. **Client timeouts too long:** a stuck Redis turns every request slow. Use tight timeouts (tens of ms) and circuit breakers.
10. **Lua scripts that run long** (`busy-lua-time-limit`, default 5 s, after which the server only answers `SCRIPT KILL`).

## 12. Redis vs alternatives

| | Redis / Valkey | Memcached | DragonflyDB | KeyDB | MemoryDB | DynamoDB + DAX |
|---|---|---|---|---|---|---|
| Threads | Single execution thread | Multithreaded | Multithreaded, shared-nothing | Multithreaded fork | Redis-compatible | Managed |
| Data types | Rich | Strings | Redis-compatible | Redis-compatible | Redis-compatible | Items |
| Durability | Async replica, RDB/AOF | None | Snapshots | Like Redis | **Multi-AZ transaction log (durable)** | Durable |
| Use | Default choice | Simplest pure cache at huge scale | Vertical scaling on big boxes | | Redis as a primary DB | Key-value DB with cache |

## 13. Interview questions on Redis

1. **Why is Redis single-threaded and still fast?** In-memory operations take µs; the bottleneck is network I/O, handled by an event loop (and I/O threads). Single-threaded execution removes locking and makes commands atomic.
2. **How do you make a check-and-set atomic?** A single command (`SET NX`, `INCR`), a Lua script/Function, or `WATCH`/`MULTI`/`EXEC`.
3. **Can Redis lose acknowledged writes?** Yes: async replication + failover, `appendfsync everysec` + crash, a minority-side primary during a partition until `cluster-node-timeout`. `WAIT` and `min-replicas-to-write` reduce it but don't eliminate it.
4. **How does Redis Cluster shard data?** 16,384 hash slots via CRC16; hash tags co-locate related keys; clients follow `MOVED`/`ASK` redirects.
5. **How is LRU implemented?** Approximately, by sampling keys and an eviction pool, not a full linked list.
6. **RDB vs AOF?** RDB: periodic fork snapshot, compact, loses minutes. AOF: logs every write, `everysec` loses ≤ 1 s, bigger, compacted by rewrite. Often both.
7. **How do you build a reliable queue on Redis?** `LMOVE` to a processing list plus a reaper, or Streams with consumer groups, `XACK`, and `XAUTOCLAIM`.
8. **Pub/Sub vs Streams?** Pub/Sub is fire-and-forget to connected subscribers. Streams persist messages, support consumer groups, acks, and replay.
9. **How do you find and fix a hot key?** Detect with `--hotkeys`/LFU or client sampling; fix with in-process caching, key replication across shards, or splitting the key.
10. **What happens during a fork with 40 GB of data and heavy writes?** A latency spike from page-table copying, and up to 2× memory from copy-on-write. Mitigate with smaller shards, headroom, no THP, and persistence on replicas only.
11. **Why is a Redis lock unsafe for correctness?** The holder may pause past its TTL, failover may lose the lock key, and there's no fencing token. Use etcd/ZooKeeper with fencing, or conditional writes at the resource.
12. **Sorted set time complexity?** `ZADD`/`ZREM`/`ZRANK` O(log n); `ZRANGE` O(log n + m); `ZSCORE` O(1).
