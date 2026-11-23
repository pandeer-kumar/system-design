# Case Study 21: Proximity Service (Yelp / Google Maps nearby / Nearby Friends)

> Tests: geospatial indexing for static vs moving data, read scaling, and the difference between business search (static) and friend location (dynamic).

## 1. Two variants

| | Nearby businesses (Yelp) | Nearby friends (moving users) |
|---|---|---|
| Data | ~200M businesses, rarely change | Users' locations change every ~30s |
| Writes | Low | High (location updates) |
| Reads | Very high (searches) | Moderate, plus push updates |
| Index | Precomputed, cached, read-optimized | In-memory, update-optimized, ephemeral |

## 2. Requirements (businesses)

- Search businesses within radius R (500m–20km) of (lat, lng), with filters and ranking
- Business detail pages; owners add/update businesses (visible next day is OK)
- 100M DAU, 5 searches/day → ~5K QPS avg, ~25K peak
- Latency < 200ms

## 3. Geospatial index options

| Option | Notes |
|---|---|
| 2D range query on (lat, lng) with two B-Tree indexes | Inefficient: intersecting two large ranges |
| **Geohash** | Base32 string; prefix length ≈ precision (6 chars ≈ 1.2km × 0.6km). Search the cell + 8 neighbours. Easy with any KV store or SQL `LIKE 'dr5ru%'`. Boundary and poles caveats. |
| **Quadtree** | Split cells until each has ≤ K businesses (e.g., 100). Dense cities get small cells. Built in memory at startup (~200M points → a few GB); rebuilt periodically. |
| **S2 / H3** | Hierarchical cells; region coverings; good for arbitrary shapes (geofences) |
| **PostGIS (R-tree/GiST)** | Great up to moderate scale; simple |
| **Elasticsearch geo queries** | Combined with text search and filters |

**Choice:** geohash or quadtree in memory on read replicas of a "location service," or Elasticsearch if text search + filters + geo are combined.

## 4. Architecture (businesses)

```
Client → LB → Location-Based Service (stateless, read-only, in-memory geo index or geohash → business_ids table)
                 → Business Service (details, cached) → Business DB (primary + replicas)
Owner updates → Business DB → nightly/periodic rebuild of the geo index (or CDC incremental)
```
- Read-heavy and the data is small, so **replicate the full index on every node**. No sharding needed (200M × ~100 bytes ≈ 20 GB; if that's too large, shard by region).
- Cache popular searches (`geohash6 + filters → results`).

## 5. Search algorithm

1. Choose a geohash precision based on the radius.
2. Compute the cell of the query point + 8 neighbours (covering the radius).
3. Fetch business IDs in those cells; filter by actual distance (haversine); rank by distance, rating, open now, relevance.
4. If too few results, expand to a lower precision (bigger cells).

## 6. Nearby friends (dynamic variant)

- Users share their location every ~30s → (10M active × 1/30s) ≈ 330K updates/s.
- **Location cache** (Redis): `user:{id}:loc → (lat, lng, ts)` with a TTL (stale means offline).
- **Pub/sub per user:** each user's location updates are published to their channel; friends' sessions (WebSocket servers) subscribe to the channels of their friends. On an update, a subscriber checks the distance and pushes to the client if within range.
- Redis Pub/Sub cluster sharded by channel (consistent hashing); a large number of channels is cheap.
- Alternative: geo-index users (geohash → users) and query nearby on demand. Cheaper if few people use the feature.
- Location history goes to a Cassandra time-series table asynchronously (if needed at all).

## 7. Concurrency and consistency notes

- Business updates are eventually consistent (next-day visibility OK). No contention.
- Moving users: LWW by timestamp per user is fine (only the user writes their own location; a single writer).
- Hot areas (Times Square): quadtree adaptive cells, caching of hot cells.

## 8. Follow-ups

- **Geofencing** (notify when entering an area): S2 covering of the fence; check the user's cell against the fence cells.
- **Privacy:** location granularity controls, opt-in, ephemeral storage.
