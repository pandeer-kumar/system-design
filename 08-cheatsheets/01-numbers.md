# Numbers Every Engineer Should Know

Print this one page and memorize it.

## Latency

| Operation | Time |
|---|---|
| L1 cache | 1 ns |
| L2 cache | 4 ns |
| Uncontended mutex | ~20 ns |
| Main memory | 100 ns |
| Compress 1 KB | 2 µs |
| Context switch | 2–5 µs |
| NVMe SSD random read | 20–100 µs |
| Same-datacenter round trip | 0.5 ms |
| Redis GET over network | 0.2–1 ms |
| Cross-AZ round trip | 1–2 ms |
| HDD seek | 5–10 ms |
| US coast to coast | 60–70 ms |
| US ↔ Europe | 80–150 ms |
| US ↔ Asia | 150–250 ms |

## Throughput (per node, ballpark)

| | |
|---|---|
| Stateless API server | 1K–10K RPS |
| Nginx/Envoy | 10K–100K+ RPS |
| Postgres/MySQL simple reads | 10K–50K QPS |
| Postgres/MySQL writes | 1K–10K TPS |
| Redis | 100K–200K ops/s (1M+ with pipelining) |
| Cassandra | 10K–50K writes/s |
| Kafka broker | 100s MB/s; ~1M msgs/s batched |
| WebSocket server | 100K–1M connections |
| 1 Gbps / 10 Gbps / 100 Gbps | 125 MB/s / 1.25 GB/s / 12.5 GB/s |

## Time and QPS conversions

| | |
|---|---|
| Seconds per day | 86,400 ≈ 10^5 |
| 1M / day | ≈ 12 / s |
| 100M / day | ≈ 1,200 / s |
| 1B / day | ≈ 12,000 / s |
| Peak / average | 2–3× (10× for spiky events) |

## Sizes

| | |
|---|---|
| UUID | 16 B |
| Snowflake ID / int64 | 8 B |
| Typical row / tweet / message | 100 B – 1 KB |
| Image | 200 KB – 2 MB |
| 1 min HD video (encoded) | 10–25 MB |
| 1 billion × 1 KB | 1 TB |

## Availability

| | Per year | Per month |
|---|---|---|
| 99.9% | 8.8 h | 44 min |
| 99.95% | 4.4 h | 22 min |
| 99.99% | 53 min | 4.4 min |
| 99.999% | 5.3 min | 26 s |

## Formulas

- **Little's Law:** concurrency = throughput × latency
- **Quorum:** W + R > N; consensus tolerates f failures with 2f + 1 nodes
- **Serial availability:** A_total = A1 × A2 × ...
- **Parallel availability:** 1 − (1 − A)^n (only for independent failures)
- **M/M/1 queue:** wait ∝ 1 / (1 − utilization). 90% utilization ≈ 10× service time.
- **Fan-out tail:** P(at least one slow) = 1 − (1 − p)^n
- **Consistent hashing:** adding a node moves ~K/N keys
- **Bloom filter:** ~10 bits/element → ~1% false positives
- **HyperLogLog:** ~12 KB → ~0.8% error for billions of items
- **Snowflake:** 41 bits ms ≈ 69 years; 12-bit sequence = 4,096 IDs/ms/node
- **Base62:** 62^6 ≈ 57B, 62^7 ≈ 3.5T, 62^8 ≈ 218T
