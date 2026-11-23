# Back-of-the-Envelope Estimation

The goal is **orders of magnitude** that drive decisions, not precision.

## Power-of-two and power-of-ten table

| Power | Exact | Approx | Name |
|---|---|---|---|
| 2^10 | 1,024 | 10^3 | KB (thousand) |
| 2^20 | | 10^6 | MB (million) |
| 2^30 | | 10^9 | GB (billion) |
| 2^40 | | 10^12 | TB (trillion) |
| 2^50 | | 10^15 | PB |

## Time conversions (memorize)

- 1 day = 86,400 s ≈ **10^5 s** (use 100K for quick math)
- 1 month ≈ 2.5 × 10^6 s
- 1 year ≈ 3 × 10^7 s
- **1M requests/day ≈ 12 QPS**
- **100M requests/day ≈ 1,200 QPS**
- **1B requests/day ≈ 12K QPS**
- Peak ≈ 2–3× average (up to 10× for spiky workloads like sports events or sales)

## Latency numbers (2020s hardware, rough)

| Operation | Time |
|---|---|
| L1 cache reference | 1 ns |
| Branch mispredict | 3 ns |
| L2 cache reference | 4 ns |
| Mutex lock/unlock (uncontended) | 17–25 ns |
| Main memory reference | 100 ns |
| Compress 1KB (Snappy/zstd) | 2 µs |
| Read 1 MB sequentially from memory | 3 µs |
| Context switch | 2–5 µs |
| SSD random read (NVMe) | 16–100 µs |
| Round trip within same datacenter | 500 µs |
| Read 1 MB sequentially from SSD | 50 µs–1 ms |
| Redis GET (network included) | 0.2–1 ms |
| Disk seek (HDD) | 2–10 ms |
| Read 1 MB sequentially from HDD | 5–20 ms |
| Round trip same region, cross-AZ | 1–2 ms |
| Round trip US East ↔ US West | 60–70 ms |
| Round trip US ↔ Europe | 80–150 ms |
| Round trip US ↔ Asia/Australia | 150–250 ms |
| TLS handshake (new connection) | 1–2 RTTs |

**Takeaways:**
- Memory is ~100× faster than SSD, and SSD is ~100× faster than HDD for random access.
- Cross-region round trips (~100ms) dominate everything. **Synchronous cross-region replication costs 100ms+ per write.**
- Sequential I/O is fast even on disk. That's why log-structured designs (Kafka, LSM trees) win for writes.

## Throughput rules of thumb (per node, rough)

| Component | Capacity |
|---|---|
| Web/API server (stateless, simple logic) | 1K–10K+ RPS |
| Nginx/Envoy proxy | 10K–100K+ RPS |
| PostgreSQL/MySQL (well-indexed point reads) | 10K–50K QPS |
| PostgreSQL/MySQL writes | 1K–10K TPS (depends on fsync/durability) |
| Redis (single thread) | 100K–200K ops/s (more with pipelining/cluster) |
| Cassandra node | 10K–50K writes/s |
| Kafka broker | 100s of MB/s, ~1M msgs/s with batching |
| Single WebSocket server | 100K–1M concurrent connections (memory-bound, tuned) |
| 10 Gbps NIC | ~1.25 GB/s |

## Storage sizes

| Item | Size |
|---|---|
| char (ASCII/UTF-8 English) | 1 byte |
| int / int64 / UUID | 4 / 8 / 16 bytes |
| Tweet-sized text + metadata | ~300 B – 1 KB |
| Typical DB row | 100 B – 1 KB |
| Thumbnail image | 10–50 KB |
| Photo (compressed) | 200 KB – 2 MB |
| 1 min of 1080p video | ~50–100 MB raw upload, ~10–25 MB encoded |
| 1 min of audio | ~1 MB |

## Availability numbers

| Availability | Downtime/year | Downtime/month |
|---|---|---|
| 99% | 3.65 days | 7.2 hours |
| 99.9% | 8.76 hours | 43.8 min |
| 99.95% | 4.38 hours | 21.9 min |
| 99.99% | 52.6 min | 4.38 min |
| 99.999% | 5.26 min | 26 s |

**Serial dependencies multiply:** 3 services at 99.9% each → 0.999³ ≈ 99.7%.
**Redundancy adds nines:** 2 independent replicas at 99% each → 1 − 0.01² = 99.99% (only if failures are truly independent, which they often aren't).

---

## Worked example: Twitter-like timeline

**Assumptions:** 300M DAU, each reads the timeline 10×/day and posts 0.5 tweets/day. Average 200 followers per user.

**Writes:**
- Tweets: 300M × 0.5 = 150M/day ≈ **1,700 tweets/s avg**, ~5K/s peak
- Fan-out on write: 150M × 200 = 30B timeline inserts/day ≈ **350K inserts/s** ← this is the real write load

**Reads:**
- 300M × 10 = 3B timeline reads/day ≈ **35K QPS avg**, ~100K peak

**Storage:**
- Tweet: ~1 KB with metadata → 150M × 1 KB = 150 GB/day → **~55 TB/year** (before replication ×3)
- Media is separate and much larger: say 10% of tweets have a 500 KB image → 7.5 TB/day

**Cache:**
- Timeline cache: 300M users × 800 tweet IDs × 8 bytes ≈ 2 TB → fits in a Redis cluster of roughly 30–50 nodes

**Decisions it drives:**
- 350K fan-out writes/s → need async fan-out via queue, sharded timeline store
- Celebrities with 100M followers → fan-out on write is impossible for them → hybrid approach
- Reads ≫ writes → precompute timelines

## Worked example: Chat system

- 500M DAU, 40 messages/day each → 20B msgs/day ≈ **230K msgs/s avg**
- 100 bytes/msg → 2 TB/day → ~730 TB/year
- Concurrent connections: if 20% online at peak → 100M connections → at 500K/server ≈ **200 gateway servers** (plus headroom → ~300–400)

## Estimation tips

1. **Round aggressively.** 86,400 → 100K. 2^30 → 1 billion.
2. **State assumptions** so the interviewer can correct them.
3. **Sanity check:** "350K writes/s is too much for one DB, so we need sharding or a write-optimized store."
4. **Separate average from peak.** Size for peak.
5. **Remember replication:** storage × 3 (RF=3), and keep 30–50% headroom.
6. **Compute only what you need.** If storage is obviously small, say so and move on.
