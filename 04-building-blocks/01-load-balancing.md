# Load Balancing and Proxies

## Layers

| | L4 (transport) | L7 (application) |
|---|---|---|
| Sees | IP, port, TCP/UDP | HTTP headers, path, cookies, gRPC methods |
| Speed | Very fast, can be kernel/hardware (millions of conn/s) | Slower (parses requests, terminates TLS) |
| Features | Connection-level balancing | Path routing, header routing, retries, rate limiting, auth, canary, compression |
| TLS | Pass-through (or terminate) | Usually terminates |
| Examples | AWS NLB, Google Maglev, LVS, Katran (Meta, XDP/eBPF) | AWS ALB, Nginx, Envoy, HAProxy, Traefik |

**Typical layering at scale:**
```
DNS (GeoDNS/anycast) → L4 LB (ECMP + Maglev/Katran) → L7 proxies (Envoy) → services
```

## Algorithms

| Algorithm | How | Good for | Pitfall |
|---|---|---|---|
| Round robin | Rotate | Homogeneous, uniform requests | Ignores load |
| Weighted round robin | Rotate with weights | Heterogeneous servers | Static |
| Least connections | Fewest active connections | Long-lived / variable-length requests | Needs state |
| Least response time / EWMA | Pick fastest recent | Heterogeneous latency | Can herd onto a "fast" failing node (fast errors!) |
| **Power of two choices (P2C)** | Pick 2 at random, choose the less loaded | **Default at scale**: near-optimal, no global state, avoids herding | — |
| IP hash / consistent hash | hash(client or key) → server | Session affinity, cache locality | Uneven with hot keys; rebalance on change |
| Random | Random | Simple, surprisingly OK at scale | Variance at low count |

**Power of two choices** is used by Envoy, Linkerd, Finagle, and Nginx (`random two least_conn`). Mention it.

**Fast-failing nodes trap:** a broken node that returns 500s in 1ms looks like the "least loaded / fastest" node and attracts all the traffic. Combine with **outlier detection** (eject on error rate).

## Health checks

- **Active:** LB probes `/health` every N seconds.
- **Passive (outlier detection):** observe real traffic errors and latency, and eject bad hosts.
- **Liveness vs readiness (Kubernetes):** liveness = should I restart this? Readiness = should I send traffic? Don't fail liveness on dependency failures (or every pod restarts when the DB blips).
- **Health check depth trade-off:** shallow checks miss gray failures; deep checks that include shared dependencies can mark **every** instance unhealthy at once, and the LB then has nothing to route to. Many LBs "fail open" (route to all) when every host is unhealthy.

## Session affinity (sticky sessions)

- Route the same client to the same server (cookie or IP hash).
- ✅ Local caches, WebSocket continuity.
- ❌ Uneven load, and failover loses the session. **Prefer stateless services with external session stores (Redis).**

## Global load balancing

- **GeoDNS:** resolve to the nearest region (Route 53 latency/geo routing).
- **Anycast:** the same IP from many PoPs; BGP picks the nearest. Fast failover (BGP withdrawal) but no fine-grained control.
- **Global L7 (e.g., Google Cloud LB, Cloudflare):** anycast front end plus L7 routing to backends in any region.
- Failover considerations: DNS TTL caching, health-check-driven routing, capacity in the surviving regions (N+1 regions).

## Client-side load balancing

- The client gets an endpoint list (from service discovery) and balances itself (gRPC, Finagle, Ribbon).
- ✅ No extra hop and no LB bottleneck.
- ❌ Logic in every client language (mitigated by a **service mesh** sidecar, or proxyless gRPC with xDS).

## Connection draining and deploys

- On deploy, stop sending new requests and let in-flight ones finish (deregistration delay, ~30s).
- Long-lived connections (WebSockets, gRPC streams) need **graceful close + client reconnect with jitter**.
- **gRPC/HTTP2 long-lived connections imbalance:** new instances get no traffic because clients keep their existing connections. Fix: max connection age (`MAX_CONNECTION_AGE`) to force periodic reconnects.

## Interview sound bites

- "L4 load balancers with ECMP at the edge for raw throughput, then Envoy at L7 for routing, retries, and outlier detection."
- "Power-of-two-choices balancing with least outstanding requests. It avoids herding without global state."
- "Readiness checks that fail on a shared DB can drain the whole fleet at once, so I keep them local and rely on outlier detection plus circuit breakers for dependencies."
