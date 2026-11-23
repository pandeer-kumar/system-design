# Microservices, Service Discovery, and Service Mesh

## Monolith vs microservices

| | Modular monolith | Microservices |
|---|---|---|
| Deploy | One unit | Independent per service |
| Scaling | Whole app | Per service |
| Data | One DB (with module boundaries) | DB per service |
| Transactions | Local ACID | Sagas / outbox |
| Latency | In-process calls (ns) | Network calls (ms), plus failure modes |
| Team scaling | Merge conflicts, coordination | Team autonomy (Conway's law) |
| Ops overhead | Low | High (discovery, tracing, CI/CD per service, on-call) |

**Senior stance:** microservices solve an **organizational scaling** problem first, technical second. Start with a well-modularized monolith; extract services when there's a clear reason (independent scaling, team ownership, different reliability requirements, tech constraints). Amazon Prime Video famously moved a monitoring component *back* to a monolith and cut costs 90%.

## Service boundaries

- Align with **business capabilities / bounded contexts** (DDD): Orders, Payments, Inventory, Shipping.
- **High cohesion, low coupling.** If two services always change together or need atomic transactions together, they're probably one service.
- **Database per service:** no other service reads your tables directly. Share via APIs or events.
- Avoid the **distributed monolith:** services that must deploy together or make synchronous call chains 6 deep.

## Communication

| Style | Use |
|---|---|
| Sync request/response (REST/gRPC) | Queries; when the caller needs the answer now |
| Async events (Kafka) | Notifying others of state changes; decoupling |
| Async commands (queue) | Background work |

**Minimize synchronous chains.** Availability multiplies: 5 services in series at 99.9% gives 99.5%. Latency adds up.

## API gateway and BFF

- **API gateway:** single entry point. Auth, rate limiting, routing, TLS, request aggregation (Kong, AWS API Gateway, Envoy, Apigee).
- **Backend for Frontend (BFF):** a separate gateway per client type (web, iOS, TV) that aggregates and shapes responses for that client (Netflix, SoundCloud). GraphQL is often used as a BFF.

## Service discovery

See [03-distributed-systems/09-membership-gossip.md](../03-distributed-systems/09-membership-gossip.md). In Kubernetes: Services + DNS; for advanced cases, xDS from a control plane.

## Service mesh

A **sidecar proxy** (Envoy) next to every service instance, configured by a **control plane** (Istio, Linkerd, Consul Connect).

- **mTLS** between services (zero-trust identity, SPIFFE)
- Retries, timeouts, circuit breaking, outlier detection
- Traffic shifting (canary, blue/green), fault injection
- Uniform metrics and traces without code changes
- **Costs:** latency per hop (~1ms), resource overhead, operational complexity. Ambient / sidecar-less modes (Istio ambient, eBPF Cilium) reduce the overhead.

## Configuration and feature flags

- Centralized dynamic config (etcd, Consul, LaunchDarkly, AWS AppConfig).
- **Roll out config changes like code** (staged, validated, with rollback). Global config pushes are a leading cause of large outages.

## Deployment strategies

| Strategy | How | Trade-off |
|---|---|---|
| Rolling | Replace instances gradually | Mixed versions during rollout |
| Blue/green | Full parallel environment, switch traffic | 2× resources; instant rollback |
| Canary | Small percentage of traffic to the new version, watch metrics | Needs good metrics and automation |
| Shadow / dark launch | Duplicate traffic to the new version, discard responses | Safe validation of behaviour and performance |
| Feature flags | Deploy dark, enable gradually per user/segment | Flag debt |

## Data consistency across services

Outbox + events + sagas + idempotency + reconciliation. See the distributed transactions chapter.

## Testing

- Contract tests (Pact) between consumer and provider
- Integration tests with ephemeral environments
- Testing in production: canaries, synthetic monitoring

## Interview sound bite

> "I'll split this into Order, Inventory, and Payment services along bounded contexts, each owning its data. They communicate via events through an outbox, and checkout is an orchestrated saga. The read path for the product page aggregates through a BFF with tight timeouts and fallbacks per dependency, so one slow service degrades a widget rather than the page."
