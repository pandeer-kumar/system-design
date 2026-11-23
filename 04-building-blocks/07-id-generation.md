# Unique ID Generation

## Requirements to clarify

- **Unique** globally? (always)
- **Sortable by time?** (feeds, pagination, DB index locality)
- **Size:** 64-bit (fits in a `BIGINT`, fast) vs 128-bit
- **Unpredictable?** (security: don't expose sequential order IDs or user counts)
- **Throughput:** IDs/sec per node and globally
- **Coordination:** can we afford a network call per ID?

## Options

### 1. Database auto-increment
- ✅ Simple, compact, ordered.
- ❌ Single point of failure and bottleneck; leaks business volume; hard across shards.
- **Multi-master variant:** server k of N generates `k, k+N, k+2N...` (Flickr ticket servers used two MySQL servers with odd and even IDs). Not time-ordered across servers.

### 2. UUID v4 (random, 128-bit)
- ✅ No coordination at all; generate anywhere, including clients (for idempotent creates).
- ❌ 128 bits; **random → terrible B-Tree locality** (page splits, cache misses on inserts); not sortable.

### 3. UUID v7 (time-ordered, 128-bit; RFC 9562, 2024)
- 48-bit Unix ms timestamp + random bits.
- ✅ No coordination, **time-sortable**, good index locality. **The modern default if 128 bits is OK.**
- ULID is a similar earlier spec (Crockford base32 encoding).

### 4. Twitter Snowflake (64-bit)
```
| 1 bit sign | 41 bits timestamp (ms since custom epoch) | 10 bits machine ID | 12 bits sequence |
```
- 41 bits of ms ≈ **69 years**.
- 10 bits → 1,024 machines (often split 5 datacenter + 5 worker).
- 12 bits → **4,096 IDs per ms per machine** (~4M/s per machine).
- ✅ 64-bit, roughly time-ordered (**k-sorted**: ordered across machines only to clock precision), no coordination per ID.
- ❌ **Clock dependence:** if the clock moves backward, you could generate duplicates. **Mitigation: refuse to generate (or wait) until the clock passes the last timestamp.**
- ❌ Machine ID assignment needs coordination at startup (ZooKeeper/etcd lease, or config/K8s StatefulSet ordinal).
- Variants: Instagram (shard ID embedded: 41 time + 13 shard + 10 sequence, generated inside Postgres with PL/pgSQL), Discord, Sony Sonyflake (10ms units, longer life), Baidu UidGenerator.

### 5. Segment / range allocation (Meituan Leaf, "Hi/Lo")
- A central DB hands out **ranges** (e.g., 1,000 IDs at a time) to each app server: `UPDATE seq SET max_id = max_id + 1000 WHERE biz_tag='order' RETURNING max_id`.
- The server serves IDs from memory; it prefetches the next segment when 10–20% remain (**double buffering**).
- ✅ Very fast, compact, monotonic per server, survives brief DB outages.
- ❌ Not globally time-ordered; gaps on restart (fine); leaks volume.

### 6. Centralized ticket service with consensus
For strictly monotonic global IDs (rare need): a single leader issuing sequence numbers (Raft-backed). Throughput is limited; batch to scale.

## Comparison

| Method | Size | Sortable | Coordination | Throughput | Notes |
|---|---|---|---|---|---|
| Auto-increment | 64 | ✅ strict | Every ID | Low–Med | SPOF |
| UUIDv4 | 128 | ❌ | None | Unlimited | Poor index locality |
| UUIDv7 / ULID | 128 | ✅ (ms) | None | Unlimited | Modern default |
| Snowflake | 64 | ✅ (k-sorted) | Machine ID at startup | ~4M/s/node | Clock skew care |
| Segment (Leaf) | 64 | Per-node | Per segment | Very high | Gaps |

## Special cases

### Short codes (URL shortener)
- Base62 encode a 64-bit counter or Snowflake → 7 characters gives 62^7 ≈ 3.5 trillion values.
- Avoid sequential guessability: encode with a bijective shuffle (multiply by a large coprime mod 62^7, or Feistel cipher), or use random codes plus a uniqueness check.
- See [06-case-studies/01-url-shortener.md](../06-case-studies/01-url-shortener.md).

### Client-generated IDs for idempotency
Client generates a UUID for an order/message before sending. Retries reuse it → **server-side dedupe via PK**. Used in chat apps (client message ID), payments, and offline-first apps.

### Message ordering IDs in chat
Per-conversation sequence numbers (assigned by the conversation's owning server or a DB atomic increment per conversation) give a **strict order within a chat**, which a global Snowflake can't guarantee across senders.

## Interview sound bite

> "I'll use Snowflake-style 64-bit IDs: 41-bit timestamp, 10-bit worker ID leased from etcd at startup, 12-bit sequence. They're roughly time-ordered, so they double as cursor keys for pagination and keep B-Tree inserts append-mostly. If the clock goes backwards, the generator waits rather than risk duplicates."
