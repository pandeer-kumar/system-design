# Case Study 22: Distributed Cache (design Memcached/Redis Cluster)

> Tests: consistent hashing, replication and failover, eviction, hot keys, client vs proxy routing, and cache consistency at scale (Facebook memcache paper).

## 1. Requirements

**Functional:** `get`, `set` (with TTL), `delete`; optionally atomic `incr`, CAS.

**Non-functional**

- 10M+ ops/s across the cluster; sub-millisecond p99 latency
- TBs of RAM across hundreds of nodes
- Scale out without downtime; tolerate node failures (the cache may lose data, but must not cause an outage)

## 2. Single node design

- Hash table in memory + **LRU** eviction (doubly-linked list or approximate LRU via sampling, as Redis does).
- Memory management: **slab allocator** (Memcached) to avoid fragmentation, with size classes; or jemalloc (Redis).
- Concurrency: Memcached is multithreaded with striped locks; Redis uses a single execution thread (no locks, atomic ops) + I/O threads.
- Lazy expiration (check TTL on access) + active sampling of expired keys.

## 3. Distribution

**Consistent hashing with virtual nodes** (see [03-distributed-systems/04-partitioning.md](../03-distributed-systems/04-partitioning.md)), or **fixed hash slots** (Redis Cluster: 16,384 slots assigned to nodes; moving a slot = migrating its keys).

**Routing options:**

| | Client-side (smart client) | Proxy (Twemproxy, mcrouter, Envoy) | Server redirect (Redis Cluster MOVED/ASK) |
|---|---|---|---|
| Latency | Best (direct) | +1 hop | Direct after topology learned |
| Client complexity | High (every language) | Low | Medium |
| Topology changes | Clients must learn | Central | Redirects teach clients |

Facebook uses **mcrouter** (a proxy) for routing, replication, failover pools, and warm-up.

## 4. Replication and failover

- Pure caches (Memcached) often have **no replication**. A node loss means misses go to the DB. That's acceptable only if the DB can absorb it.
- **Gutter pool (Facebook):** when a node fails, its traffic goes to a small dedicated "gutter" pool with short TTLs instead of rehashing onto healthy nodes (which would cascade the load) or hitting the DB directly.
- Redis Cluster: primary + replicas per slot range; replicas are promoted on failure (detected by gossip/majority of primaries). **Async replication means acknowledged writes can be lost on failover.**

## 5. Hot keys

- Detect (sampling at the proxy, LFU counters).
- Replicate hot keys to multiple nodes (key suffixes), and use local L1 caches in app servers with short TTLs.
- Facebook: regional "leader/follower" pools; very hot keys are served from many replicas.

## 6. Consistency with the database (Facebook memcache lessons)

- **Look-aside cache; delete on write** (not update).
- **Leases** to solve the stale-set race and thundering herds: on a miss, the client gets a lease token; only the lease holder may set; other clients wait briefly or use a stale value.
- **Invalidation via MySQL binlog tailing (McSqueal):** reliable, batched deletes broadcast to all regions/clusters.
- **Cross-region:** a "remote marker" to avoid reading stale data from a local replica DB right after a write in the primary region.
- See the paper summary in [07-real-world/01-papers.md](../07-real-world/01-papers.md).

## 7. Scaling operations

- **Adding nodes:** consistent hashing moves ~1/N keys. With pure caches that means a cold miss spike for those keys; warm the new node gradually (mcrouter warm-up routes: on a miss in the new node, read from the old node).
- **Cold cluster start:** warm from another cluster before taking traffic (Facebook's "cold cluster warm-up").
- **Connection count:** thousands of app servers × hundreds of cache nodes = a huge number of connections. Use proxies, UDP for gets (Facebook), and connection multiplexing.

## 8. Failure modes

| Failure | Handling |
|---|---|
| Node failure | Replica promotion (Redis) / gutter pool / misses to DB with rate limiting |
| Network partition in Redis Cluster | The minority side's primaries stop accepting writes after `cluster-node-timeout`; risk of lost writes |
| Mass expiry | TTL jitter |
| Cache poisoning (bad value cached) | Versioned keys, a quick global purge tool |
