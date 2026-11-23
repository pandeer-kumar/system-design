# Case Study 09: Video Streaming (YouTube / Netflix)

> Tests: large-file upload pipelines, transcoding at scale (a DAG of parallel jobs), CDN design, adaptive bitrate streaming, and metadata vs blob separation.

## 1. Requirements

**Functional**

- Upload videos (YouTube) or ingest studio content (Netflix)
- Transcode into multiple resolutions and codecs
- Stream with adaptive quality on any device
- Metadata: title, description, thumbnails, view counts, search, recommendations

**Non-functional**

- YouTube: 500+ hours uploaded per minute; billions of views/day
- Playback start < 2s; minimal rebuffering
- High availability for playback; upload processing can take minutes
- Global, cost-efficient (bandwidth is the dominant cost)

## 2. Estimation

- Upload: 500 h/min × 60 min × ~1 GB/h (raw-ish) ≈ **30 TB/hour of raw uploads**
- Transcoded outputs: ~5–10 renditions → storage × ~2–3 of the original (more efficient codecs per rendition)
- Egress: 1B hours watched/day at ~3 Mbps avg ≈ **~1.4 Tbps average... in practice hundreds of Tbps at peak**. Only feasible with CDNs and ISP-embedded caches.

## 3. Upload pipeline

```
1. Client → Upload API: create video (metadata row: status=UPLOADING) → pre-signed resumable multipart URLs
2. Client → Object storage (S3/GCS) direct upload, chunked, resumable
3. Upload complete → event → Kafka "video_uploaded"
4. Processing orchestrator (DAG):
     validate/scan → split into segments (GOP-aligned, ~2–10s)
       → parallel transcode each segment × each rendition (H.264/VP9/AV1; 144p … 4K)
       → assemble → package (HLS/DASH manifests) → thumbnails → captions (ASR) → content ID / moderation
5. Outputs → object storage (origin) → status=READY → notify uploader; index for search
```

### Why split into segments
A 2-hour 4K video transcoded serially takes hours. Splitting into chunks gives **massive parallelism** (thousands of workers), with retries at chunk granularity. Netflix's encoding pipeline uses chunk-based parallel encoding with per-title / per-shot optimized bitrate ladders.

### Orchestration and concurrency

- A DAG/workflow engine (Netflix Conductor/Cosmos, Temporal, Airflow-like) tracks task state.
- Tasks are **idempotent** (output path deterministic from `(video_id, segment, rendition)`, so a re-run overwrites the same object).
- At-least-once task execution with leases/heartbeats. If a worker dies, its task lease expires and another worker picks it up.
- Priority queues: popular creators or live content get priority; GPU/ASIC encoders (YouTube uses custom VCU chips).

## 4. Streaming: adaptive bitrate (ABR)

- Video is packaged as **small segments** (2–10s) per rendition, plus a **manifest** (HLS `.m3u8` / DASH `.mpd`) listing renditions and segment URLs.
- The player measures throughput and buffer level, and picks the rendition for each next segment (switching quality mid-stream without stalling).
- Segments are plain HTTP objects, so they're **perfectly cacheable by CDNs**.

## 5. CDN strategy

- **Popularity is power-law:** a small fraction of videos makes up most views.
- **YouTube:** Google's global edge (Google Global Cache inside ISPs) + tiered caching. Long-tail videos are served from regional caches or the origin.
- **Netflix Open Connect:** Netflix-owned appliances inside ISPs, **pre-filled during off-peak hours** with content predicted to be popular in that region (the catalog is known in advance, unlike UGC). The steering service directs each client to the best appliance.
- **Origin shield** + request coalescing so a viral video doesn't stampede the origin.
- Signed URLs/tokens for access control; DRM (Widevine/FairPlay/PlayReady) for premium content.

## 6. Metadata and the playback API

```
videos(video_id, uploader_id, title, description, status, duration, renditions JSON, created_at)  -- sharded MySQL (YouTube uses Vitess)
```
Playback request:

1. `GET /watch?v=ID` → metadata service (cached heavily) → returns the manifest URL + the best CDN host (steering)
2. Player fetches manifest + segments directly from the CDN

## 7. View counts (concurrency at scale)

- Billions of increments/day; hot videos get millions/min.
- **Don't** `UPDATE videos SET views=views+1` (a hot row).
- Client/player emits view events → Kafka → stream aggregation (dedupe, fraud filtering, validity rules like ">30s watched") → batched increments every N seconds to a counter store → cached display value.
- Displayed counts are **eventually consistent** (YouTube famously froze counts at "301+" while validating views).
- See [19-distributed-counter.md](19-distributed-counter.md).

## 8. Live streaming (if asked)

- Ingest via RTMP/SRT/WebRTC → transcode in real time → segment (low-latency HLS/DASH, 1–2s parts) → CDN.
- Latency: standard HLS 10–30s; LL-HLS 2–5s; WebRTC < 1s (but harder to scale).
- Chat for live streams is a separate fan-out problem (see the chat case study; large-room optimizations).

## 9. Failure modes

| Failure | Handling |
|---|---|
| Upload interrupted | Resumable multipart uploads |
| Transcode worker crash | Lease expiry → re-run idempotent segment task |
| Poison video (crashes the encoder) | Retry limits → DLQ → mark FAILED, notify the user |
| CDN PoP failure | Steering/DNS routes to the next-best PoP; the player retries other hosts |
| Origin overload on a viral video | Origin shield, request collapsing, pre-warming |

## 10. Follow-ups

- **Deduplication / content ID:** perceptual fingerprints (audio/video) matched against a reference DB.
- **Recommendations:** offline candidate generation + online ranking; precomputed home rows (Netflix).
- **Search:** metadata + transcripts indexed in a search cluster.
- **Cost optimization:** better codecs (AV1 saves ~30% bandwidth vs VP9), per-title encoding, storage tiering for cold videos (fewer renditions kept; re-transcode on demand).
