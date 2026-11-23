# Case Study 08: Ride Sharing (Uber / Lyft)

> Tests: high-frequency location updates, geospatial indexing, matching under concurrency (one driver, two riders), state machines, and real-time tracking.

## 1. Requirements

**Functional**
- Rider requests a ride (pickup, dropoff) and sees an ETA and price
- Match to a nearby available driver; the driver accepts or declines
- Live location tracking of the driver during the trip
- Trip lifecycle: requested → matched → driver arriving → in progress → completed → paid

**Non-functional**
- 20M rides/day; 5M active drivers, ~1M online at peak
- Drivers send location every **4 seconds** → ~250K location updates/s
- Matching latency: a few seconds
- **A driver must never be assigned to two rides at once**
- Highly available; regional (cities are naturally partitioned)

## 2. Estimation

- Location updates: 1M drivers / 4s = **250K writes/s** (small payloads, ~100 bytes → 25 MB/s)
- Ride requests: 20M/day ≈ 230/s avg, ~2K/s peak
- Location data is ephemeral (latest position matters for matching; history goes to cold storage for analytics and trip receipts)

## 3. High-level design

```
Driver app ──(location every 4s, WebSocket/UDP-ish)──> Location Gateway ──> Location Service
                                                                  │  ├─ update geo index (in-memory, sharded by region/cell)
                                                                  │  └─ Kafka (location stream → trip tracking, analytics, ETA models)
Rider app ──> API ──> Ride Service (trip state machine, DB)
                         └──> Matching/Dispatch Service ──> query geo index for nearby available drivers
                                                         ──> offer ride to driver(s) ──> Driver app
                         └──> Pricing (surge), ETA service (routing engine)
Trip tracking: driver locations for active trips pushed to the rider via WebSocket
```

## 4. Deep dive: geospatial indexing

Need: "find available drivers within ~2km of a point," with positions changing every 4s.

| Approach | How | Notes |
|---|---|---|
| **Geohash** | Encode lat/lng into a base32 string; shared prefix = nearby. Query the cell + 8 neighbours | Simple; works with any KV store; edge effects at cell boundaries (hence neighbours) |
| **Quadtree** | Recursively subdivide areas with many points | Adapts to density; harder to update with frequent moves |
| **Google S2** | Sphere → cube → Hilbert curve cells; 64-bit cell IDs at 30 levels | Uniform-ish cells, good covering of arbitrary regions; used by Uber (earlier), Google, Foursquare |
| **Uber H3** | Hexagonal hierarchical grid | Hexagons have equidistant neighbours (better for ring queries and surge pricing areas) |
| **Redis GEO** | Sorted set with geohash scores; `GEOSEARCH` | Easy; good per-city scale |
| **PostGIS / R-tree** | Spatial index in the DB | Great for static data; heavy for 250K updates/s |

**Design:** an in-memory index keyed by **H3/S2 cell → set of available driver IDs**, sharded by city/region (consistent hashing on cell ID). On each location update: if the driver changed cells, remove from the old cell and add to the new one. Query = cells within k rings of the pickup cell → candidate drivers → filter by actual distance and ETA (road network, not straight line).

**Why in memory:** 250K updates/s of ephemeral data. Persisting every update to a DB is wasteful. Keep the latest location in memory (replicated) and stream to Kafka for history.

## 5. Deep dive: matching without double-assignment (concurrency core)

Problem: two dispatch processes (for two nearby riders) both pick driver D at the same time.

**Option 1: Atomic driver state transition (preferred)**
```
Driver state: AVAILABLE → OFFERED(ride_id, expires) → ON_TRIP
Claim:  UPDATE drivers SET state='OFFERED', ride_id=:r, offer_expires=now()+15s
        WHERE id=:d AND state='AVAILABLE'
-- or Redis: Lua/CAS on driver:{id}:state, or SET driver:{id}:lock ride_id NX EX 15
```
Only one dispatcher succeeds; the other picks the next candidate.

**Option 2: Single writer per geo region**
- Each dispatch shard owns a region (a set of cells). All matching decisions for drivers in that region are made **sequentially** by its owner, so there's no race by construction. Uber's dispatch (DISCO) partitioned supply and demand geographically with consistent hashing (Ringpop).
- Batch matching: collect requests over a ~1–2s window and solve the assignment globally for the region (better total ETAs than greedy nearest-driver).

**Drivers at region boundaries:** a driver near a boundary might be visible to two shards. Either assign ownership by the driver's current cell (one owner), or still require the atomic claim on the driver's state as a final guard.

**Offer timeout:** a driver gets ~15s to accept. On timeout or decline, revert to AVAILABLE (conditional: `WHERE state='OFFERED' AND ride_id=:r`) and offer the next candidate. Use a **delayed message / timer** for expiry.

**Idempotency:** a ride request retried from a flaky mobile network carries a client request ID, so the server dedupes and doesn't create two rides.

## 6. Deep dive: trip state machine

```
REQUESTED → MATCHING → DRIVER_ASSIGNED → DRIVER_ARRIVED → IN_PROGRESS → COMPLETED → PAID
     └→ CANCELED (by rider/driver/no drivers)
```
- Stored in a strongly consistent DB (Schemaless/MySQL at Uber, later Docstore; Postgres, Spanner).
- **Conditional transitions** (`WHERE status = expected`) prevent races such as the rider canceling at the same moment the driver accepts. Exactly one wins; the other gets "trip already canceled/accepted."
- Events emitted via the outbox → notifications, billing, analytics.

## 7. Deep dive: live tracking

- The driver's location stream (Kafka, keyed by driver) feeds a **trip tracking service** that pushes positions to the rider via WebSocket or SSE.
- Interpolate on the client for smoothness (map matching to roads).
- Mobile networks drop. Send the latest position on reconnect; don't replay history.

## 8. Deep dive: location ingestion at 250K/s

- Drivers connect to **location gateways** (WebSocket/QUIC); batch updates where possible.
- Gateways forward to the location service shard owning the driver's region.
- Update the in-memory index (fast path) + publish to Kafka (async, for history).
- Backpressure: if overloaded, **drop intermediate updates** (only the latest matters). Ephemeral data can be lossy.

## 9. Surge pricing (brief)

- Stream processing (Flink) computes supply/demand per H3 cell per minute → surge multiplier → cached for the pricing service.
- **Price lock:** the quote shown to the rider is stored with an ID and expiry; the request references the quote ID. That prevents a "price changed" race.

## 10. Failure modes

| Failure | Handling |
|---|---|
| Geo index node dies | Rebuilt within seconds from the next round of location updates (drivers update every 4s), plus replicas |
| Dispatch shard dies | Ownership moves to another node (consistent hashing + membership); in-flight offers expire and are retried |
| Driver app loses connectivity mid-trip | Trip continues; locations are buffered on the device and uploaded later; fare from GPS trace and odometer |
| Payment failure at trip end | Trip still completes; payment retried asynchronously; account flagged |
| Data center failure | Uber ran active-active with trip state replicated; the driver app holds some trip state as a backup to recover |

## 11. Follow-ups

- **ETA:** a routing engine on the road graph (contraction hierarchies) + ML for traffic; precomputed per cell pair.
- **Pooling (shared rides):** matching becomes a vehicle-routing optimization; batch windows.
- **Why not a DB for driver locations?** Write rate and ephemerality. An in-memory index plus a stream is cheaper and faster.
- **Multi-city:** partition everything by city/region; most queries are city-local.
