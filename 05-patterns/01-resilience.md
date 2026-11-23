# Resilience Patterns

How to keep a distributed system up when its parts fail. Interviewers expect you to use these by name **with reasons**.

## 1. Timeouts

- **Every network call needs a timeout.** The default in many clients is infinite.
- Set from latency data: ~p99.9 of the dependency, bounded by the caller's own budget.
- **Deadline propagation:** pass the remaining time budget downstream (gRPC deadlines). If 50ms remain, don't make a call that needs 200ms.
- Separate **connect timeout** (short, ~100ms–1s) from **request timeout**.

## 2. Retries (with backoff, jitter, budgets)

```
delay = random(0, min(cap, base × 2^attempt))     # "full jitter"
```
- Retry only **transient** errors (timeouts, 503, 429, connection reset), and only **idempotent** operations or those with an idempotency key.
- **Retry budget:** retries ≤ 10–20% of total requests (Finagle/Envoy). Without a budget, retries multiply load during outages, which is the classic metastable failure.
- **Retry at one layer.** Nested retries multiply (3 retries × 4 layers = 81 attempts).
- **Hedged requests:** send a second request to another replica if the first hasn't returned by the p95 latency. Cuts tail latency for idempotent reads at ~5% extra load. (Google "The Tail at Scale".)

## 3. Circuit breaker

```
CLOSED ──(failures > threshold)──> OPEN ──(after cooldown)──> HALF-OPEN
   ↑                                                              │
   └───────────(trial requests succeed)───────────────────────────┘
                 (trial fails) → back to OPEN
```
- **Closed:** requests flow; track the error rate over a sliding window.
- **Open:** fail fast without calling the dependency (return an error, cached data, or a fallback).
- **Half-open:** allow a few trial requests; close if they succeed.
- ✅ Stops wasting resources on a dead dependency, gives it room to recover, and fails fast for users.
- Libraries: Resilience4j, Polly (.NET), Envoy outlier detection, Hystrix (retired, but the idea came from it).

## 4. Bulkheads (isolation)

Named after ship compartments: a leak in one doesn't sink the ship.
- **Separate thread pools / connection pools / semaphores per dependency.** A slow recommendations service can't consume the threads that serve checkout.
- **Separate clusters for critical vs non-critical traffic.**
- **Cell-based architecture:** partition the whole stack (app + DB) into independent cells, each serving a subset of customers. A failure or bad deploy affects one cell (AWS uses this extensively; Slack and DoorDash moved toward cells).
- **Shuffle sharding (AWS Route 53):** each customer is assigned a random subset of k workers out of N. Two customers rarely share the exact same set, so a "poison" customer impacts few others. With N=8 and k=2, there are 28 combinations.

## 5. Backpressure

When consumers can't keep up, **signal producers to slow down** rather than buffering without limit.
- Bounded queues: when full, block, reject, or drop.
- TCP flow control, gRPC/HTTP2 flow control windows, Reactive Streams `request(n)`.
- Kafka consumers pull at their own pace (natural backpressure; lag grows instead).
- At HTTP level: return `429`/`503` with `Retry-After`.

## 6. Load shedding

Under overload, **reject excess requests early and cheaply** to keep serving the rest within SLO.
- Shed at the edge, before doing expensive work.
- **Prioritize:** critical (checkout) > normal (browse) > sheddable (prefetch, analytics). Google tags requests with criticality.
- **LIFO under overload:** the oldest requests in the queue have probably already timed out at the client, so serve the newest first (Meta's adaptive LIFO + CoDel for queues).
- **CoDel (controlled delay):** drop requests whose queue wait exceeds a target.
- **Admission control based on concurrency** (adaptive concurrency limits) rather than fixed RPS.

## 7. Graceful degradation / fallbacks

- Recommendations down → show popular items.
- Personalization down → generic feed.
- Search down → show categories.
- Payment provider A down → route to provider B.
- Serve **stale cache** (`stale-if-error`).
- **Feature flags/kill switches** to turn off expensive features under load.

**Don't** make fallbacks more complex than the primary path. A rarely exercised fallback is often broken. Test it (chaos engineering).

## 8. Rate limiting and quotas

Per-client limits prevent one tenant from starving others. See [04-building-blocks/08-rate-limiting.md](../04-building-blocks/08-rate-limiting.md).

## 9. Idempotency

Makes retries safe. See [02-concurrency/06-idempotency.md](../02-concurrency/06-idempotency.md).

## 10. Health checks and auto-healing

Replace unhealthy instances automatically (ASGs, Kubernetes). Combine with outlier detection for gray failures.

## 11. Redundancy and failover

- N+1 / N+2 capacity: survive losing one AZ **at peak** (with 3 AZs, each needs 50% of peak capacity).
- Active-active preferred (always exercised) over active-passive (standby may silently rot).
- **Static stability (AWS):** the system keeps working during a dependency failure **without needing to make changes** (pre-provisioned capacity in each AZ, not "scale up when the AZ fails," because the control plane might be down too).

## 12. Safe deployments (most outages are changes)

- Canary → small percentage → AZ → region → global, with **automated rollback** on metric regression.
- Feature flags decouple deploy from release.
- **Bake time** between stages.
- Config changes deserve the same rigor as code (many global outages were config pushes).
- Backward-compatible schema and API changes (expand/contract).

## 13. Chaos engineering

- Intentionally inject failures in production (Netflix Chaos Monkey, Gremlin, AWS FIS): kill instances, add latency, partition networks, fail an AZ.
- **Game days** to rehearse incident response.
- Verifies that the resilience patterns actually work.

## Putting it together: a resilient call

```
Request
  → Rate limit / load shed at edge (by priority)
  → Deadline set (e.g., 800ms total)
  → Bulkhead (semaphore: max 50 concurrent to Payment Service)
  → Circuit breaker (open? → fallback)
  → Timeout (min(remaining_deadline, 300ms))
  → Retry (≤2, jittered backoff, within retry budget, idempotency key)
  → Fallback on failure (cached/default/queue for later)
  → Metrics + trace span
```

## Interview sound bite

> "Calls to the inventory service go through a bulkhead and a circuit breaker with a 200ms timeout and at most one retry under a 10% retry budget. If the breaker opens, we show 'availability may be delayed' and queue the reservation instead of failing the page. Load shedding at the gateway drops prefetch traffic first when we pass 80% capacity."
