# Case Study 28: Object Storage (design S3)

> Tests: metadata vs data separation, durability math, erasure coding, placement across failure domains, strong consistency for metadata, multipart upload, garbage collection, and background repair. A staff-level storage question.

## 1. Requirements

**Functional**
- Buckets; `PUT object` (up to 5 TB via multipart), `GET` (including byte ranges), `DELETE`, `LIST` by prefix (paginated)
- Versioning (optional), lifecycle policies, pre-signed URLs, access control

**Non-functional**
- **Durability: 11 nines** (99.999999999%) per object per year
- Availability 99.99% for reads
- **Strong read-after-write consistency** (as S3 provides since 2020), including LIST
- Exabytes of data; trillions of objects; millions of requests/s; per-prefix throughput scaling
- Cost-efficient (storage overhead matters more than anything at this scale)

## 2. Architecture

```
Clients ─► Front-end / API fleet (auth, request routing, signature validation)
              │                                    │
              ▼                                    ▼
   Metadata service                       Data (blob) service
   bucket + key → object metadata         stores immutable data chunks on storage nodes
   (versions, size, checksum,             placement across AZs, erasure coding,
    chunk locations / placement group)    background repair & scrubbing
   strongly consistent, partitioned       ▲
              │                           │
              └── Garbage collector / lifecycle workers / repair coordinators
```

**The key idea:** separate the **small, mutable, strongly consistent metadata** from the **large, immutable data**. Each scales and replicates differently.

## 3. Data path

### PUT (single part)
1. The front end authenticates and computes the target bucket/key.
2. It streams the bytes to the data service, which splits them into chunks (e.g., 8–64 MB), **erasure-codes** each chunk, and writes the fragments to storage nodes in **different AZs/racks**. It verifies checksums (client-supplied `Content-MD5`/CRC64 + per-fragment checksums).
3. Only after the data is durable does the front end **commit the metadata** (`key → version → chunk locations, size, checksum, etag`) in the metadata store. **The metadata commit is the linearization point**: the object becomes visible atomically.
4. Return 200.

A crash after step 2 but before step 3 leaves orphaned chunks; garbage collection reclaims them (never the other way around: metadata never points to data that isn't durable).

### GET
Look up the metadata (latest version, or a specific one) → read the needed fragments (any k of n) → reconstruct and verify checksums → stream. Range GETs read only the needed chunks.

### Multipart upload (large objects)
`CreateMultipartUpload` → upload parts in parallel (each is stored like a small object, with its own checksum) → `CompleteMultipartUpload(list of parts)` commits metadata pointing to the parts **in one atomic metadata update**. Parts never completed are cleaned up by a lifecycle rule (abort incomplete uploads after N days).

## 4. Deep dive: durability math and erasure coding

**Replication (3 copies):** 200% overhead.
**Erasure coding (Reed-Solomon k + m):** split into k data fragments + m parity fragments; any k reconstruct. E.g., **(10, 4)** → 40% overhead and tolerates 4 lost fragments.

**Placement constraint:** the code must survive losing a whole AZ. With 3 AZs, (10, 4) puts ~5 fragments in each AZ, and losing one AZ removes 5 > 4, so the data is unreadable. Choose parameters where one AZ's share is ≤ m with margin for disk failures. Examples:
- **(9, 6)** across 3 AZs: 5 fragments per AZ; losing an AZ leaves 10 ≥ 9, plus one more disk failure tolerated. Overhead 67%.
- **(6, 6)**: 4 per AZ; an AZ loss plus 2 more failures tolerated. Overhead 100% (still cheaper than 3× replication).
- Or keep a cheaper code **within** each AZ and **replicate across** AZs (more overhead, but simpler and faster repair).

The general rule: **fragments per failure domain ≤ m − (extra failures you want to survive)**.

**What drives the 11 nines:**
- Independent failure domains (disks, hosts, racks, AZs)
- **Fast repair:** durability depends on how quickly a lost fragment is rebuilt before more fail (MTTR). Repairs read k fragments to rebuild one, so they need bandwidth budgeting; locally repairable codes (LRC, used by Azure) reduce repair reads.
- **Scrubbing:** background reading of all data to detect silent corruption (bit rot) via checksums, repairing proactively.
- End-to-end checksums from client to disk and back.
- Software safety: deployment safety, deletion protections (much data loss in practice is from bugs and operator error, not disks).

Typical choice: replicate small or hot objects (cheaper reads, latency), erasure-code everything else (storage cost).

## 5. Deep dive: the metadata service

- **Scale:** trillions of keys; billions of requests/day. Must support **strongly consistent** point reads/writes and **ordered prefix listing**.
- **Partitioning:** range-partitioned by `(bucket, key)` so `LIST prefix` is a range scan. Partitions split automatically on size or **request rate** (S3's per-prefix performance scaling: a hot prefix gets split across more partitions).
- **Hot-spot caveat:** sequential key names (timestamps as prefixes) concentrate writes on one partition until it splits. Historically S3 advised randomized prefixes; automatic splitting mostly removed the need, but sudden extreme load still needs ramp-up time.
- **Replication:** each partition is a consensus group (Paxos/Raft) across AZs. Writes are linearizable; reads served by the leader (or with a lease) for read-after-write consistency.
- **Strong consistency including LIST:** the listing index is updated in the same atomic metadata transaction as the object record (or the index is the primary structure), so a LIST right after a PUT includes it.
- **Conditional writes:** `If-None-Match: *` (create only if absent) and `If-Match: etag` (compare-and-swap) are naturally supported by a consensus-backed metadata store, which lets clients build simple coordination on S3.

## 6. Deep dive: placement and the data service

- Storage nodes with many disks; a **placement service** chooses fragment locations: different AZs, racks, and hosts; balanced by free space and load; avoiding nodes being drained.
- Writes go to **fresh, empty-ish** volumes to spread load; data is immutable once written (no in-place updates), so overwrites create new data and old data becomes garbage.
- **Heat management:** new data is hot; rebalancing spreads it so no disk becomes a hotspot (Amazon has described managing "heat" across millions of drives).

## 7. Deep dive: delete, versioning, and garbage collection

- **Delete** = a metadata operation (remove the key, or add a **delete marker** in versioned buckets). Data chunks become unreferenced.
- **Garbage collection** finds unreferenced chunks (mark-and-sweep against metadata, or reference counts with care) and frees them after a grace period (to cover in-flight reads and uncommitted multipart uploads).
- **Lifecycle policies:** transition to colder storage classes (fewer replicas, more erasure coding, slower media) or expire after N days, run by background workers that scan metadata.

## 8. Request path concerns

- **Pre-signed URLs:** a signature over (method, bucket, key, expiry) with the user's key, so clients upload/download directly without proxying through your app.
- **Throughput:** clients parallelize with multipart uploads and ranged GETs; front ends are stateless and horizontally scaled behind DNS and load balancers.
- **Rate limits per prefix/bucket** with `503 SlowDown`, and clients retry with backoff.

## 9. Failure modes

| Failure | Handling |
|---|---|
| Disk / host dies | Fragments reconstructed elsewhere from k survivors; repair prioritized by how many fragments the stripe has lost |
| AZ outage | Reads reconstruct from the remaining AZs; writes placed in healthy AZs (degraded placement, later rebalanced) |
| Metadata partition leader dies | Consensus elects a new leader; brief unavailability for that key range |
| Crash between data write and metadata commit | Orphaned data, garbage-collected later; the object never becomes visible half-written |
| Silent corruption | Checksums on every read + background scrubbing → repair from other fragments |
| Operator / software error deleting data | Soft-delete grace periods, versioning, object lock (WORM), staged deployments |

## 10. Follow-ups

- **Small objects** (KBs): erasure-coding each one wastes overhead and I/O. Pack small objects into larger "extents" (like Facebook Haystack / f4), with the metadata pointing to (extent, offset, length).
- **LIST performance on huge buckets:** paginate with continuation tokens (the last key), served by the range-partitioned index.
- **Event notifications** on PUT/DELETE → a queue (for transcoding pipelines).
- **Cross-region replication:** asynchronous, per-bucket rules; RPO = replication lag.
- **Cost model discussion:** storage class per access frequency; erasure coding parameters; egress is the hidden cost.
