# Locks, Synchronization Primitives, and Deadlocks

## Primitives

| Primitive | Semantics | Use case |
|---|---|---|
| **Mutex** | One holder at a time | Protect a critical section |
| **Reentrant lock** | Same thread can re-acquire | Recursive calls (Java `synchronized`, `ReentrantLock`) |
| **Read-write lock** | Many readers OR one writer | Read-heavy shared data (config, caches) |
| **Spinlock** | Busy-wait instead of sleeping | Very short critical sections, kernels |
| **Semaphore** | N permits | Limit concurrency (connection pools, rate limits, bulkheads) |
| **Condition variable** | Wait until a condition, signal/broadcast | Producer-consumer |
| **Barrier / latch** | Wait until N threads arrive | Phased computation, startup coordination |
| **StampedLock / seqlock** | Optimistic reads with validation | Very read-heavy, small data |

### Read-write lock pitfalls
- **Writer starvation:** a constant stream of readers blocks writers forever. Fair RW locks queue readers behind waiting writers.
- RW locks have more overhead than a mutex. They only pay off when read critical sections are long and reads dominate.

### Semaphores as a system design tool
- **Bulkhead:** a semaphore of 20 for calls to the payment service. When it's exhausted, fail fast instead of piling up threads.
- **Concurrency limiting:** max 100 in-flight requests per downstream (more adaptive than rate limiting; see Netflix's `concurrency-limits` library).

## Deadlock

### The four Coffman conditions (all must hold)
1. **Mutual exclusion:** a resource is held exclusively.
2. **Hold and wait:** holding one resource while waiting for another.
3. **No preemption:** resources can't be forcibly taken.
4. **Circular wait:** T1 waits for T2, which waits for T1.

Break any one and deadlock is impossible.

### Prevention strategies
| Strategy | Breaks | Example |
|---|---|---|
| **Global lock ordering** | Circular wait | Always lock accounts in ascending ID order when transferring |
| **Try-lock with timeout** | Hold and wait | `tryLock(100ms)`; on failure release everything, back off, retry |
| **Acquire everything at once** | Hold and wait | Lock all needed rows in a single statement |
| **Lock-free algorithms** | Mutual exclusion | CAS-based structures |
| **Leases / TTLs** | No preemption | Distributed locks expire |

### Classic interview: bank transfer
```python
def transfer(a, b, amount):
    first, second = sorted([a, b], key=lambda x: x.id)  # lock ordering
    with first.lock:
        with second.lock:
            a.balance -= amount
            b.balance += amount
```
In SQL:
```sql
BEGIN;
SELECT * FROM accounts WHERE id IN (:a, :b) ORDER BY id FOR UPDATE;
UPDATE accounts SET balance = balance - :amt WHERE id = :a AND balance >= :amt;
UPDATE accounts SET balance = balance + :amt WHERE id = :b;
COMMIT;
```

### Database deadlocks
- Databases **detect** deadlocks (wait-for graph cycle detection) and abort one transaction (the victim).
- **The application must retry** on deadlock errors (MySQL `1213`, Postgres `40P01`).
- Reduce them: consistent access order, short transactions, proper indexes (otherwise you lock more rows than intended, or gap locks in MySQL).

### Distributed deadlock
- Spanning multiple nodes means no single wait-for graph. Detection is hard.
- Usual approach: **timeouts** (assume deadlock after X seconds) or **wound-wait / wait-die** using timestamps:
  - **Wait-die:** an older transaction waits for a younger one; a younger one requesting from an older one aborts ("dies").
  - **Wound-wait:** an older transaction preempts ("wounds") the younger one; a younger one waits. (Spanner uses wound-wait.)

## Livelock and starvation

- **Livelock:** threads keep reacting to each other and make no progress (two people stepping aside in a hallway). Common with naive retry-on-conflict. **Fix: randomized jitter.**
- **Starvation:** a thread never gets the resource (unfair locks, priority inversion).
- **Priority inversion:** a high-priority task waits on a lock held by a low-priority task, which is preempted by a medium-priority one. (Mars Pathfinder, 1997.) Fix: priority inheritance.

## Producer-consumer and bounded buffers

```
Producers → [ bounded queue (capacity N) ] → Consumers
```
- When the queue is full, producers **block, drop, or get rejected**. This is backpressure.
- When the queue is empty, consumers wait (condition variable or blocking queue).
- **This is the same pattern as Kafka, SQS, and every work queue in system design.** The bounded size is what keeps the system stable under overload.

## Lock granularity trade-off

```
Coarse (global lock) ←———————————————→ Fine (per-field lock)
simple, low overhead,                   high concurrency,
low concurrency                         more overhead, deadlock risk
```
**Lock striping:** N locks, with key → `lock[hash(key) % N]`. A middle ground (early `ConcurrentHashMap`, and the same idea as sharding).

## Lock-free and wait-free

- **Lock-free:** at least one thread always makes progress (CAS loops).
- **Wait-free:** every thread finishes in bounded steps (harder; rare in practice).
- **Obstruction-free:** a thread makes progress if run in isolation.

Lock-free isn't automatically faster. Under heavy contention, CAS retry storms can lose to a good mutex. Measure.

## Interview checklist when you introduce a lock

- [ ] What exactly does it protect? (the invariant)
- [ ] What's the granularity? Can it be finer?
- [ ] How long is it held? Is there I/O inside it? (Never do network calls while holding a lock if you can avoid it.)
- [ ] What's the acquisition order? Can it deadlock?
- [ ] What happens if the holder crashes? (Distributed: lease and fencing.)
- [ ] What's the contention level? Will it be a bottleneck at peak?
- [ ] Could you avoid it entirely (partitioning, single writer, atomic op)?
