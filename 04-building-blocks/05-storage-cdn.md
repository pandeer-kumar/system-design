# Blob Storage, CDN, and File Systems

## Storage types

| Type | Interface | Examples | Use |
|---|---|---|---|
| **Block** | Raw blocks (a disk) | EBS, Persistent Disk, SAN | DB volumes, VMs |
| **File** | POSIX hierarchy | EFS, NFS, HDFS, GFS/Colossus | Shared files, legacy apps, big data |
| **Object** | HTTP PUT/GET by key, flat namespace | S3, GCS, Azure Blob, MinIO | Media, backups, data lakes, static assets |

## Object storage (S3) essentials

- **Durability:** 11 nines via erasure coding / replication across ≥3 AZs.
- **Consistency:** S3 has been **strongly read-after-write consistent** for PUTs and DELETEs since Dec 2020 (GCS also strong). Older material says "eventually consistent"; that's outdated.
- **Throughput:** scales per prefix (thousands of requests/sec per prefix; partitions split automatically). Spread hot keys across prefixes.
- **Large files:** **multipart upload** (parallel parts of 5 MB–5 GB, resumable, up to 5 TB per object).
- **Pre-signed URLs:** clients upload/download **directly to S3** with a time-limited signed URL. **Don't proxy large files through your app servers.**
- **Storage classes:** Standard → Infrequent Access → Glacier (archive). Lifecycle policies move data automatically.
- **Event notifications:** object created → SNS/SQS/Lambda (triggers transcoding pipelines).
- **Conditional writes** (`If-None-Match`, `If-Match`) are now supported, which allows simple compare-and-swap on S3 objects.

### Upload flow pattern (use in every media case study)
```
1. Client → API: "I want to upload video.mp4 (500MB)"
2. API → creates metadata row (status=UPLOADING), returns pre-signed multipart URLs
3. Client → S3 directly (parallel parts, resumable)
4. Client → API: "complete" (or S3 event notification)
5. API/S3 event → queue → processing workers (transcode, thumbnail, virus scan)
6. Workers → write outputs to S3 → update metadata (status=READY)
```

### Metadata vs data separation
Store **blobs** in object storage and **metadata** (owner, size, checksum, location, permissions) in a database. Every file system and media service at scale follows this pattern.

## Erasure coding vs replication

- **Replication (3×):** 200% overhead, simple, fast recovery.
- **Erasure coding (e.g., Reed-Solomon 6+3):** split into 6 data + 3 parity chunks; any 6 reconstruct the data. **50% overhead** with tolerance for 3 failures. CPU cost and slower reconstruction.
- Hot data is often replicated; warm/cold data erasure-coded. (Facebook f4 warm BLOB storage, HDFS EC, S3.)

## Distributed file systems (GFS/HDFS)

- **Master/NameNode:** metadata (namespace, file → chunks → locations), in memory.
- **Chunk servers/DataNodes:** store 64–128 MB chunks, replicated 3×.
- Clients get locations from the master, then read/write chunks **directly** to chunk servers (the master stays off the data path).
- Write pipeline: data flows through a chain of replicas; a **lease** to the primary replica orders mutations.
- Optimized for large sequential reads and appends, not small random writes.
- Master SPOF mitigated with a standby plus shared edit log (HDFS HA with a ZooKeeper-based failover controller); GFS successor Colossus distributes metadata (stored in Bigtable).

## Content-addressable storage

- Key = **hash of content** (SHA-256).
- ✅ Automatic **deduplication**, integrity verification, immutable (cache forever).
- Used by Git, Docker image layers, Dropbox (chunk hashes), IPFS, backup systems.

## CDN (Content Delivery Network)

**Edge servers (PoPs)** worldwide cache content close to users.

### Push vs pull
| | Pull (origin pull) | Push |
|---|---|---|
| How | Edge fetches from origin on first miss | You upload content to the CDN ahead of time |
| Pros | Simple, automatic | Control; no first-request miss |
| Cons | First request slow; origin load on misses | Manage uploads, storage cost |
| Use | Most websites, APIs | Large, predictable content (video releases, game patches) |

### Key concepts
- **Cache-Control headers:** `max-age`, `s-maxage` (shared caches), `stale-while-revalidate`, `stale-if-error`, `no-store`, `private`.
- **Cache key:** URL + selected headers/cookies. Too many variations kill the hit rate.
- **Invalidation/purge:** slow-ish (seconds to minutes) and sometimes costly. **Prefer versioned URLs** (`/app.3f2a1b.js`, `/img/123_v2.jpg`).
- **Origin shield / tiered caching:** a mid-tier cache in front of the origin, so 300 PoPs missing don't make 300 origin requests. **Request collapsing** at the shield.
- **Edge compute:** Cloudflare Workers, Lambda@Edge for auth, A/B tests, personalization at the edge.
- **Signed URLs/cookies** for private content (paid video).
- **Dynamic content acceleration:** even uncacheable API calls benefit (TLS termination near the user, persistent optimized connections to the origin).

### Video-specific CDN behaviour
- Segment-based streaming (HLS/DASH): each 2–10s chunk is a cacheable object.
- **Netflix Open Connect:** Netflix places its own cache appliances **inside ISPs** and **pre-positions** content during off-peak hours based on predicted popularity. ~95%+ of traffic is served from these.
- Long-tail content has low CDN hit rates, so it's served from regional caches or the origin.

## Interview sound bites

- "Clients upload directly to S3 using pre-signed multipart URLs, so our API servers never touch the bytes."
- "Static assets use content-hashed filenames with a one-year max-age, so we never need to purge."
- "An origin shield with request collapsing protects the origin when a new video goes viral and every PoP misses at once."
- "Metadata lives in Postgres; blobs live in S3 keyed by content hash, which gives us dedup for free."
