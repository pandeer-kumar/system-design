# Concurrency Fundamentals

## Concurrency vs parallelism

- **Concurrency:** dealing with many things at once (structure). Tasks overlap in time, possibly on one core.
- **Parallelism:** doing many things at once (execution). Tasks run simultaneously on multiple cores or machines.

A single-threaded event loop (Node.js, Redis) is concurrent but not parallel.

## Processes, threads, coroutines

| | Process | OS thread | Green thread / coroutine |
|---|---|---|---|
| Memory | Isolated address space | Shared within the process | Shared |
| Creation cost | ~ms | ~10–100 µs, ~1 MB stack | ~µs, ~KB stack |
| Context switch | Expensive (TLB flush) | ~2–5 µs (kernel) | ~100 ns (user space) |
| Scheduling | Kernel | Kernel (preemptive) | Runtime (cooperative or preemptive) |
| Examples | Postgres backends, Chrome tabs | Java platform threads, pthreads | Goroutines, Java virtual threads, Kotlin coroutines, Python asyncio |
| How many | 100s | 1,000s–10,000s | Millions |

**Why it matters for system design:** thread-per-request with OS threads caps you at a few thousand concurrent requests per server. If each request blocks 200ms on I/O, 1,000 threads ≈ 5,000 RPS max. Event loops and virtual threads remove that ceiling for I/O-bound work.

## Race conditions

A **race condition** is when correctness depends on the relative timing of operations.

### Classic: read-modify-write (lost update)
```
Thread A: read counter (10)
Thread B: read counter (10)
Thread A: write 11
Thread B: write 11      ← one increment lost
```
This exact bug appears **at every level**: CPU registers, DB rows (`SELECT` then `UPDATE`), cache entries (`GET` then `SET` in Redis), and across microservices.

### Check-then-act (TOCTOU)
```python
if not seat.is_booked():     # check
    seat.book(user)          # act. Someone else may have booked in between!
```
Fixes: make check-and-act **atomic** (conditional write, compare-and-swap, unique constraint, lock).

### Data race vs race condition
- **Data race:** two threads access the same memory concurrently, at least one writes, with no synchronization. Undefined behaviour in C/C++, Go, and Rust (Rust prevents it at compile time).
- **Race condition:** a logic-level timing bug. Can exist even with no data races (for example, every access is individually atomic but the sequence isn't).

## Atomicity, visibility, ordering

Three separate problems:

1. **Atomicity:** an operation happens all at once or not at all. `count++` is three operations: load, add, store.
2. **Visibility:** a write by one thread is seen by another. CPU caches and registers can hide writes indefinitely without synchronization.
3. **Ordering:** compilers and CPUs reorder instructions. Another thread might see `ready = true` before `data = 42`.

### Memory models (senior-level awareness)
- A **memory model** defines which reorderings are allowed and what "happens-before" means.
- **Happens-before:** if A happens-before B, A's effects are visible to B. Established by locks (unlock → lock), volatile/atomic writes → reads, thread start/join, and channel send → receive.
- **Java:** `volatile` gives visibility and ordering but not compound atomicity. `synchronized` and `java.util.concurrent` give all three.
- **C++/Rust:** `std::atomic` with orderings (`relaxed`, `acquire`, `release`, `seq_cst`).
- **Go:** "Don't communicate by sharing memory; share memory by communicating" (channels).

**The classic bug:** double-checked locking without `volatile` in Java. Another thread can see a non-null reference to a partially constructed object.

## Atomic operations and CAS

**Compare-And-Swap (CAS):** `CAS(addr, expected, new)` atomically sets `*addr = new` if `*addr == expected` and returns success or failure. This is the hardware primitive under lock-free structures.

```java
// Lock-free increment
do {
    old = counter.get();
} while (!counter.compareAndSet(old, old + 1));
```

- **Pros:** no blocking, no deadlock, good under low contention.
- **Cons:** under high contention, threads spin and retry (wasted CPU). Also the **ABA problem**: the value goes A→B→A and CAS wrongly succeeds. Fix with version stamps (`AtomicStampedReference`) or tagged pointers.
- **Under high contention**, prefer sharded counters (`LongAdder` in Java keeps per-cell counters and sums on read). **The same idea is used in distributed sharded counters.**

### The same pattern in distributed systems

| Local | Distributed equivalent |
|---|---|
| CAS | Conditional write: `UPDATE ... WHERE version = 5`, DynamoDB `ConditionExpression`, etcd `Txn(If(mod_rev == X))`, Redis `WATCH/MULTI` |
| Mutex | Distributed lock (ZooKeeper, etcd, Redis), DB row lock (`SELECT FOR UPDATE`) |
| Atomic counter | Redis `INCR`, DB `UPDATE x = x + 1` |
| LongAdder (sharded counter) | Sharded counter rows, merged on read |
| Thread-confined data | Partition ownership (single writer per key) |
| Message passing / channels | Queues, Kafka partitions, actors |

**This table is key.** Almost every distributed concurrency problem is a local concurrency problem with added latency and partial failure.

## Contention: the scalability killer

- **Amdahl's law:** serialized sections cap speedup.
- **Lock convoys:** threads queue on a hot lock; throughput collapses to single-thread speed or worse because of context switches.
- **False sharing:** independent variables on the same 64-byte cache line ping-pong between cores. Fix with padding (`@Contended` in Java).
- **Hot rows / hot keys:** the distributed version. One DB row taking all the writes (a global counter, a popular item's stock).

### Ways to reduce contention (in order of preference)
1. **Don't share.** Partition the data so each piece has a single owner (thread confinement, sharding by key).
2. **Immutable data.** Readers need no synchronization (copy-on-write, persistent data structures, event logs).
3. **Shard the contended resource.** Striped locks, sharded counters.
4. **Batch.** Take the lock once for N operations (group commit, write coalescing).
5. **Reduce critical section size.** Do the expensive work outside the lock.
6. **Use optimistic concurrency** when conflicts are rare.
7. **Use finer-grained locks.** Row instead of table, per-key instead of global.
8. **Queue it.** Serialize through a single consumer; this turns contention into ordering.

## Thread safety strategies

- **Immutability:** final fields, no setters. Safe to share freely.
- **Confinement:** only one thread touches it (thread-local, actor-owned).
- **Synchronization:** locks, monitors.
- **Concurrent data structures:** `ConcurrentHashMap` (lock striping and CAS), `ConcurrentLinkedQueue` (lock-free), `CopyOnWriteArrayList` (read-heavy).

## Thread pools and sizing

- **CPU-bound:** threads ≈ number of cores (maybe +1).
- **I/O-bound:** threads ≈ cores × (1 + wait_time / compute_time). Or apply Little's Law: threads = throughput × latency.
- **Always use bounded queues.** An unbounded queue in front of a pool means memory grows until you OOM under overload. A bounded queue plus a rejection policy is backpressure.
- **Separate pools per dependency (bulkheads)** so one slow downstream can't consume every thread.

## Key interview takeaways

1. Every "read, then decide, then write" across a network is a potential race. Make it atomic or tolerate it.
2. Contention, not raw CPU, usually limits scale. Remove shared mutable state where you can.
3. The local primitives (CAS, locks, queues, sharded counters) map directly to distributed ones.
