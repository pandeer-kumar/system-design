# Case Study 17: Stock Exchange / Order Matching Engine

> Tests: deterministic single-threaded processing, sequencers, state machine replication, ultra-low latency, fairness, and why "no locks" beats "fast locks."

## 1. Requirements

**Functional**

- Place orders (limit, market), cancel orders
- Match buy and sell orders by **price-time priority**
- Publish market data (order book updates, trades)
- Risk checks before acceptance (buying power, position limits)

**Non-functional**

- Latency: **microseconds** for matching (p99 < 100µs inside the engine); ms end to end
- Throughput: millions of orders/s across symbols; a hot symbol at ~100K+ orders/s
- **Fairness and determinism:** the same input gives the same output; strict ordering
- **No lost orders, no double fills**
- High availability: failover in seconds or less, without losing state

## 2. Order book

Per symbol:

- **Bids:** sorted by price descending, then time ascending
- **Asks:** sorted by price ascending, then time ascending
- Structure: a map of price level → FIFO queue of orders (sorted map or array indexed by price ticks), plus an order_id → order index for O(1) cancels.

Matching: an incoming buy at price P matches the lowest asks ≤ P in time order until it's filled or no more matches; the remainder rests on the book (limit) or is canceled (IOC/market).

## 3. Architecture

```
Brokers/Clients → Gateways (FIX/binary protocol, auth, throttling)
     → Pre-trade Risk checks
     → SEQUENCER (assigns a global sequence number per input, journals it)
     → Matching Engine (per symbol partition, single-threaded, in-memory)
     → Output events (sequenced): acks, fills, book updates
     → Market Data Publisher (multicast UDP / feeds)
     → Post-trade: clearing, settlement, reporting (async, via the event log)
```

## 4. Deep dive: why single-threaded

- The matching of a symbol's order book is **inherently sequential** (price-time priority needs a total order).
- Locks would add contention and nondeterminism. A single thread per symbol (or per partition of symbols) with everything in memory and in CPU cache runs millions of operations per second.
- **LMAX Disruptor:** a lock-free ring buffer between the I/O threads and the business logic thread; mechanical sympathy (cache-line padding, preallocation, no garbage collection in the hot path).
- Partition **by symbol** for parallelism: each engine instance handles a set of symbols. Hot symbols get dedicated cores.

## 5. Deep dive: the sequencer and determinism

- Every input event (new order, cancel) gets a **monotonic sequence number** and is **journaled** (durable) before or alongside processing.
- The matching engine is a **deterministic state machine:** `state_n+1 = f(state_n, input_n)`. No wall-clock reads, no randomness, no external calls in the matching logic (timestamps come from the sequencer).
- **Replication = state machine replication:** standby engines consume the same sequenced input stream and compute identical state. Failover means promoting a hot standby that's already up to date.
- **Recovery:** load a snapshot + replay the journal from the snapshot's sequence number.
- The sequencer itself must be highly available (primary-backup with fencing, or a consensus-replicated log). Some exchanges use Raft-style replication for the input log (e.g., Aeron Cluster).

## 6. Deep dive: risk checks and concurrency

- Pre-trade risk (does the account have buying power?) must be consistent with fills.
- Common pattern: the risk engine is **also sequenced** (same single-writer model per account partition). It reserves buying power on order acceptance and releases it on cancel or fill (a reservation/escrow pattern).
- Avoid cross-partition synchronous calls in the hot path.

## 7. Market data

- Each book change produces an incremental update with a sequence number; multicast to subscribers.
- Subscribers detect gaps by sequence number and request retransmission or snapshots.
- Fairness: equal-length cables in colocation, simultaneous release.

## 8. Latency engineering (talking points)

- Kernel bypass networking (DPDK, Solarflare/OpenOnload), busy-spinning threads pinned to cores, NUMA awareness
- No allocations or garbage collection on the hot path (object pools; or C++/Rust/Java with off-heap memory)
- Binary protocols (SBE) instead of JSON
- Batching journal writes (group commit) with replication to the standby before ack

## 9. Failure modes

| Failure | Handling |
|---|---|
| Matching engine crash | Hot standby (same input stream) promoted; clients resume with sequence numbers |
| Sequencer failure | Replicated sequencer with fencing; clients resend unacked orders with client order IDs (dedup) |
| Duplicate order submission | Client order ID unique per session → reject duplicates |
| Gateway overload | Per-client throttles; reject with a clear error (never queue unboundedly) |
| Bug producing a wrong match | Kill switch / trading halt; deterministic replay for forensics |

## 10. Takeaways that apply beyond exchanges

1. **Single writer + deterministic processing + journaled input** = no locks, easy replication, easy recovery.
2. Partition by the natural unit of contention (symbol, account, game room).
3. Sequence numbers everywhere make gaps and duplicates detectable.
4. Keep slow things (settlement, reporting, analytics) off the hot path via the event log.
