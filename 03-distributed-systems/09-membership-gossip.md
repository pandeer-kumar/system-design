# Membership, Failure Detection, and Gossip

## The problem

In a cluster of hundreds or thousands of nodes, each node needs to know who is alive, who joined, and who left, **without a single point of failure** and without O(N²) messaging.

## Failure detectors

### Heartbeat with fixed timeout
Nodes send heartbeats every T; declare dead after k×T of silence.

- Simple, but a fixed threshold is brittle: network jitter causes false positives, and long timeouts mean slow detection.

### Phi (φ) Accrual Failure Detector (Hayashibara et al.)

- Instead of a binary alive/dead, output a **suspicion level φ** from the statistical distribution of heartbeat inter-arrival times.
- `φ = -log10(P(heartbeat arrives later than now))`
- Applications pick a threshold (Cassandra default φ = 8, which means ~1 in 10^8 chance of a false positive under the model).
- **Adapts** to network conditions automatically. Used by Cassandra and Akka.

### Properties

- **Completeness:** every crashed node is eventually suspected
- **Accuracy:** no live node is suspected (impossible to guarantee perfectly in async systems)
- Trade-off: faster detection means more false positives

## Gossip protocols (epidemic dissemination)

Each node periodically (e.g., every 1s) picks **random peer(s)** and exchanges state.

- Information spreads like an epidemic: reaches all N nodes in **O(log N)** rounds.
- **Robust:** no single point of failure; tolerates message loss and node failures.
- **Scalable:** constant load per node per round.
- **Eventually consistent:** convergence isn't instant.

### Gossip styles

- **Push:** send my updates to a random peer
- **Pull:** ask a random peer for its updates
- **Push-pull:** both (fastest convergence)
- **Anti-entropy:** full state comparison (often with Merkle trees) to repair divergence
- **Rumor mongering:** spread new updates aggressively, then stop once "enough" peers know

### What gets gossiped

- Membership (who is in the cluster, with heartbeat counters/versions)
- Failure suspicions
- Cluster metadata (token ownership in Cassandra, schema versions)
- Load info for routing

### Used by

- **Cassandra** (membership, token ring, schema), **DynamoDB** internals, **Consul/Serf** (SWIM), **Redis Cluster** (cluster bus), **Riak**, **Bitcoin** (transaction propagation), **ScyllaDB**, **Uber Ringpop**

## SWIM (Scalable Weakly-consistent Infection-style Membership)

Used by HashiCorp Serf/Consul (memberlist) and Uber's Ringpop.

1. Each period, node M picks a random node J and sends `ping`.
2. If no ack, M asks **k random other nodes** to `ping-req` J (**indirect probing** avoids false positives from a bad link between M and J specifically).
3. If still no ack, J is marked **suspect** (not dead yet). The suspicion is gossiped.
4. J can **refute** by gossiping an alive message with a higher incarnation number.
5. After a suspicion timeout, J is declared **dead**.
6. Membership updates are **piggybacked** on ping/ack messages (no extra traffic).

**Properties:** constant message load per node, detection time independent of cluster size, low false-positive rate. **Lifeguard** extensions (HashiCorp) further reduce false positives from slow nodes.

## Centralized membership (alternative)

Use a consensus service (ZooKeeper/etcd) as the **source of truth** for membership:

- Nodes register ephemeral nodes / leases; when the session dies, they're removed.
- Strongly consistent view, simpler reasoning.
- Scales less well (the coordinator handles all heartbeats; sessions can storm on restart).
- **Common choice** for systems with tens to hundreds of nodes: Kafka (KRaft), HBase, Kubernetes (node leases in etcd).

## Gossip vs centralized

| | Gossip | Centralized (ZK/etcd) |
|---|---|---|
| Consistency of view | Eventual | Strong |
| Scale | 1,000s–10,000s nodes | 100s–1,000s |
| SPOF | None | The coordination cluster (replicated) |
| Convergence | O(log N) rounds | Immediate (on write) |
| Complexity | Protocol subtleties | Operating ZK/etcd |

## Service discovery

How clients find healthy instances of a service:

| Approach | How | Examples |
|---|---|---|
| **DNS-based** | Service name resolves to instance IPs | Kubernetes Services (ClusterIP + kube-proxy), Consul DNS |
| **Client-side discovery** | Client queries registry, load balances itself | Netflix Eureka + Ribbon, gRPC xDS |
| **Server-side discovery** | Client calls LB/proxy, which queries registry | AWS ALB, Kubernetes Ingress |
| **Service mesh** | Sidecar proxies get endpoints from control plane | Istio/Envoy (xDS), Linkerd |

**Eureka's design choice is worth knowing:** it's AP. During a partition, it keeps serving the last known registry ("self-preservation mode") instead of evicting instances, on the reasoning that stale entries plus client retries beat an empty registry.

## Interview usage

- "Nodes discover each other and detect failures via gossip (SWIM-style), so there's no SPOF, and it scales to thousands of nodes. Shard-ownership metadata, which must be strongly consistent, lives in etcd."
- "I'll use an accrual failure detector instead of a fixed timeout to reduce false failovers from GC pauses."
