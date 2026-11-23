# Failure Modes and the Reality of Networks

## The 8 fallacies of distributed computing (Deutsch, 1994)

1. The network is reliable
2. Latency is zero
3. Bandwidth is infinite
4. The network is secure
5. Topology doesn't change
6. There is one administrator
7. Transport cost is zero
8. The network is homogeneous

Every one is false, and every design must account for them.

## Failure types (from easiest to hardest to handle)

| Failure | Description | Example |
|---|---|---|
| **Crash-stop** | Node stops and never returns | Hardware dies |
| **Crash-recovery** | Node stops, later restarts (maybe losing in-memory state) | Process restart, reboot |
| **Omission** | Messages lost | Packet drops, full queues |
| **Timing / performance** | Node responds, but too slowly | GC pause, overloaded, noisy neighbor |
| **Byzantine** | Node behaves arbitrarily or maliciously | Bit flips, bugs, attackers |

Most data-center systems assume **crash-recovery with omission and timing failures**, not Byzantine (blockchains handle Byzantine).

## Partial failure is the defining problem

On a single machine, things mostly work or crash entirely. In a distributed system, **some parts fail while others work**, and **you often can't tell which**.

When you send a request and get no response:

- The request may be lost
- The remote node may be down
- The remote node may be slow (GC pause, overloaded)
- The request was processed, but the response was lost
- The response is delayed and will arrive later

**You cannot distinguish these.** The only tool is a **timeout**, and a timeout can't tell you whether the operation happened, which is why idempotency matters.

## Gray failures (the most dangerous in practice)

The component isn't fully down; it's degraded. Health checks pass (they check "is the process up?") but real requests fail or are slow.

- One disk with high latency
- A NIC dropping 2% of packets
- A node that serves health checks but times out on DB calls
- A "zombie" leader that has lost its lease but doesn't know it yet

Mitigations:

- **Deep health checks** that exercise real dependencies (carefully, or you get cascading failure when a shared dependency dies)
- **Outlier detection:** eject hosts with elevated error rate or latency (Envoy outlier detection)
- **Client-side observability:** measure success from the caller's view

## Network partitions

- **Full partition:** two groups can't talk to each other.
- **Partial partition:** A can talk to B, and B to C, but A can't reach C. These break naive leader-election logic.
- **Asymmetric:** A→B works, B→A doesn't.

Partitions are real. Studies (Bailis & Kingsbury, "The Network is Reliable," 2014) show they're common in production, including within one data center.

## Process pauses

A process can freeze for seconds without knowing it:

- Stop-the-world GC (Java pauses of seconds to tens of seconds on large heaps, historically)
- VM live migration or steal time
- Swapping or page faults
- `SIGSTOP`, a debugger
- Disk I/O stall on a synchronous write (fsync in a full-disk situation)

**Implication:** a node can't trust "I checked my lease 1ms ago, so I still have it." Hence fencing tokens.

## Timeouts: how to set them

- Too short: false positives cause unnecessary failovers and retry storms.
- Too long: slow detection; users wait and threads pile up.
- Base them on **observed latency distributions:** e.g., timeout ≈ p99.9 × 1.5–2.
- **Adaptive timeouts:** the Phi Accrual failure detector (Cassandra, Akka) outputs a suspicion level, not a binary up/down. See [09-membership-gossip.md](09-membership-gossip.md).
- **Propagate deadlines** through the call chain (gRPC deadlines). Don't start work the caller has given up on.

## Cascading failures (how big outages happen)

1. One component slows down (DB under load)
2. Callers' threads/connections pile up waiting (Little's Law)
3. Callers run out of resources and start failing
4. Retries amplify load on the struggling component
5. Load balancers route away from "unhealthy" nodes, overloading the remaining ones
6. Everything falls over

**Defences:** timeouts, circuit breakers, bulkheads, load shedding, retry budgets, backpressure, autoscaling with limits. See [05-patterns/01-resilience.md](../05-patterns/01-resilience.md).

### Metastable failures
The system enters a bad state that **persists even after the trigger is removed**, sustained by its own feedback loop (retries, cache misses after a cache flush, queue backlog). Example: a cache cluster restarts, so every request goes to the DB, the DB is overloaded, requests time out, retries keep the DB overloaded, and the cache never warms. Recovering often requires **shedding load drastically** (blocking traffic) until the system stabilizes.

## Correlated failures

Redundancy only helps if failures are independent. They often aren't:

- Same bad deploy rolled out everywhere
- Same bug triggered by the same input (a leap second, a poison message)
- Shared dependency (DNS, auth, config service)
- Same hardware batch, same power or cooling
- Certificate expiry on all nodes at once

**Defences:** staged rollouts (one cell, then one AZ, then one region), cell-based architecture, diversity, and avoiding global config pushes. Many major cloud outages were global config changes (see [07-real-world/02-outages-postmortems.md](../07-real-world/02-outages-postmortems.md)).

## Byzantine and data corruption (lightweight)

Even without malicious nodes:

- Use **checksums** on disk and network (TCP's 16-bit checksum misses errors at scale). S3, HDFS, and Kafka all checksum data.
- **End-to-end checks:** verify at the application level, not just the transport.
- Validate inputs. Poison messages can crash every consumer in turn. Use a dead-letter queue after N failures.

## Key takeaways

1. A timeout means "unknown," not "failed."
2. Design for degraded, not just dead.
3. A node can't trust its own sense of time or its lease.
4. Retries without limits turn small failures into outages.
5. Correlated failures beat naive redundancy. Isolate blast radius.
