# Core Qualities: Scalability, Availability, Reliability, Latency

## Scalability

**Definition:** the ability to handle more load by adding resources, without a redesign.

### Vertical vs horizontal

| | Vertical (scale up) | Horizontal (scale out) |
|---|---|---|
| How | Bigger machine | More machines |
| Limit | Hardware ceiling (~hundreds of cores, ~TBs of RAM) | Coordination overhead |
| Complexity | Low | High (distribution, consistency, partitioning) |
| Failure | Single point of failure | Redundancy built in |
| When | Start here. DBs often scale up first. | Stateless services, and data at large scale |

**Senior insight:** vertical scaling is underrated. A single modern Postgres box (96 cores, 1 TB RAM, NVMe) handles a huge amount of load. Stack Overflow ran on a handful of SQL Servers for years. Don't shard before you need to, because sharding is a one-way door.

### What makes something hard to scale horizontally

1. **State.** Stateless services scale trivially. State has to be partitioned or replicated.
2. **Coordination.** Anything requiring agreement (locks, transactions, consensus) limits throughput.
3. **Contention.** Many writers on the same item, such as a hot row, a global counter, or a single sequence.
4. **Fan-out.** One request triggering N downstream calls; tail latency multiplies.

### Universal Scalability Law (Gunther)

Throughput doesn't scale linearly. Two penalties:

- **Contention (α):** serialization on shared resources (Amdahl's law)
- **Coherency (β):** cost of keeping nodes in agreement, which grows with N²

```
C(N) = N / (1 + α(N-1) + βN(N-1))
```

With β > 0, adding nodes eventually **reduces** throughput. This is why chatty consensus protocols top out at 5–7 nodes and why you partition instead of growing a single cluster.

**Amdahl's law:** if 5% of work is serial, max speedup is 20× no matter how many cores you add.

## Availability

**Definition:** the fraction of time the system serves requests successfully.

```
Availability = uptime / (uptime + downtime)
             = MTBF / (MTBF + MTTR)
```

**Insight from the formula:** you can improve availability by failing less (MTBF ↑) **or recovering faster (MTTR ↓)**. Reducing MTTR (fast detection, automated failover, quick rollback) is usually cheaper and more effective.

### Techniques

- **Redundancy:** no single point of failure (N+1, N+2)
- **Failover:** active-passive (standby takes over) or active-active (all serve traffic)
- **Health checks and automatic replacement**
- **Graceful degradation:** serve partial results rather than errors
- **Load shedding:** reject some requests to keep serving the rest
- **Isolation:** cells and bulkheads to limit blast radius
- **Safe deploys:** canaries, feature flags, fast rollback. **Most outages are caused by changes.**

### Failure domains
Process → host → rack → availability zone → region → cloud provider. Replicas must sit in **different** failure domains. Three replicas on the same rack is one replica during a top-of-rack switch failure.

## Reliability vs availability vs durability

- **Reliability:** the system does the right thing (correctness over time)
- **Availability:** the system responds
- **Durability:** committed data is not lost

A system can be available but unreliable (it responds with wrong data), or durable but unavailable (data safe, service down). S3 advertises 11 nines of durability but "only" 99.99% availability.

## Latency vs throughput

- **Latency:** time for one request
- **Throughput:** requests per unit time

**Little's Law** (use this in interviews):
```
L = λ × W
concurrency = throughput × latency
```
Example: 10K RPS at 200ms latency → 2,000 requests in flight → you need enough threads, connections, and memory for 2,000 concurrent requests. If latency spikes to 2s, you suddenly need 20,000. **This is how latency spikes turn into outages**: thread pools exhaust, queues build, and timeouts cascade.

### Percentiles, not averages

- Averages hide the tail. Always talk about **p50, p99, p99.9**.
- **Tail latency amplification:** if a request fans out to 100 backends, each with p99 = 1s, then 1 − 0.99^100 = **63%** of requests see at least one 1s response.
- Mitigations: hedged requests (send a duplicate after a p95 delay), tied requests, smaller fan-out, timeouts with partial results.

> Read: "The Tail at Scale" (Dean & Barroso, 2013), summarized in [07-real-world/01-papers.md](../07-real-world/01-papers.md).

### Queueing theory intuition

Latency grows non-linearly with utilization. For an M/M/1 queue:
```
W = 1 / (μ − λ)     (service rate μ, arrival rate λ)
```
At 50% utilization, wait ≈ 2× service time. At 90%, it's 10×. At 99%, it's 100×.

**This is why you keep 30–50% headroom**, and why systems fall over suddenly instead of gradually.

## Consistency (preview)

Covered in depth in [03-distributed-systems/05-consistency-models.md](../03-distributed-systems/05-consistency-models.md). The key point is that **consistency, availability, and latency trade off against each other.**

## Maintainability, operability, cost

Interviewers at the senior level care about these:

- **Operability:** can on-call debug it at 3am? Does it have clear metrics and runbooks?
- **Simplicity:** every component you add is something that can fail and someone has to run.
- **Evolvability:** can you change the schema, add a region, or swap a component?
- **Cost:** cross-AZ data transfer, egress, storage tiers, and over-provisioning. Mention it.
