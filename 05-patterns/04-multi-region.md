# Multi-Region Architecture and Disaster Recovery

## Why multi-region

1. **Disaster recovery:** survive a region outage
2. **Latency:** serve users from nearby
3. **Data residency / compliance:** GDPR, data sovereignty laws
4. **Scale:** spread load

**Cost:** complexity, replication cost (cross-region egress is expensive), consistency trade-offs, and operational burden. Don't propose it without a requirement.

## DR metrics

- **RPO (Recovery Point Objective):** how much data you can lose (time window). Async replication gives RPO of seconds to minutes; sync gives RPO = 0.
- **RTO (Recovery Time Objective):** how long until service is restored.

## DR strategies (cheapest to most expensive)

| Strategy | Description | RTO | RPO |
|---|---|---|---|
| **Backup & restore** | Backups in another region; restore on disaster | Hours–days | Hours |
| **Pilot light** | Core data replicated; minimal infra in DR region, scaled up on failover | 10s of min | Minutes |
| **Warm standby** | Scaled-down full copy running in DR region | Minutes | Seconds–minutes |
| **Active-passive (hot standby)** | Full-scale copy, receives no traffic | Minutes | Seconds |
| **Active-active** | All regions serve traffic | ~0 (reroute) | ~0–seconds |

## Active-active patterns

### 1. Read local, write global (single write region)
- All writes go to the primary region; replicas in other regions serve reads.
- ✅ No write conflicts. ❌ Write latency for remote users; failover of the write region needed.
- Variant: **a home region per user/tenant** ("data follows the user"). Each user's writes go to their home region; most users are near their home. **This is the most practical active-active design.**

### 2. Multi-leader writes everywhere
- Every region writes locally and replicates asynchronously.
- Needs conflict resolution (LWW, CRDTs, app merge). See [03-distributed-systems/08-crdts-conflict-resolution.md](../03-distributed-systems/08-crdts-conflict-resolution.md).
- DynamoDB Global Tables (LWW), Cassandra multi-DC with `LOCAL_QUORUM`.

### 3. Globally consistent (consensus across regions)
- Spanner, CockroachDB multi-region: writes need a cross-region quorum (+50–150ms).
- Optimizations: place leaders near writers (CockroachDB `REGIONAL BY ROW`, leaseholder pinning), **follower reads / stale reads** for read-only queries.

## Partitioning data by geography

- EU users' data in EU regions only (GDPR).
- Route by user's home region (in a JWT claim, a cookie, or a global user → region directory).
- Global tables (product catalog) replicated everywhere; user tables pinned to home regions.

## Failover mechanics

- **DNS failover** (Route 53 health checks): TTL caching delays it (minutes).
- **Anycast / global LB:** faster.
- **Data layer failover:** promote the replica in the DR region. **Risk:** async replication means writes are lost (RPO > 0). Must **fence** the old primary to prevent split brain when it comes back.
- **Avoid automatic regional failover for the data layer** unless thoroughly tested. Many orgs require a human decision because false positives are very costly. Automatic failover of stateless traffic is fine.
- **Failback** is often harder than failover (reconciling divergent writes).

## Capacity planning

- With N active regions, each must handle its traffic **plus** a failed region's share. 3 regions → each at most ~66% utilized at peak normally.
- Pre-provision. Don't rely on autoscaling during a regional failure (everyone else is scaling too; control planes may be impaired). This is AWS's **static stability** principle.

## Common pitfalls

- **Hidden single-region dependencies:** auth, DNS, config, a single global DB, or a control plane in us-east-1 (several large outages trace to this).
- Untested failover (do regular game days or region evacuations; Netflix regularly evacuates whole regions).
- Cross-region chatty calls in the request path (+100ms each).
- **Cross-region egress costs.**
- Clock and ordering assumptions across regions.

## Interview sound bite

> "Users get a home region, chosen at signup from their location. All of their writes go there, so there are no write conflicts, and reads are local. Their data is replicated asynchronously to one other region for DR, giving an RPO of seconds. Global data like the catalog is replicated everywhere. On a regional outage, a human-approved failover promotes the replicas and fences the old primaries; stateless traffic fails over automatically through the global load balancer. Each region runs at ≤60% peak utilization so it can absorb a neighbour's traffic."
