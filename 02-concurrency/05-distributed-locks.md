# Distributed Locks, Leases, and Fencing Tokens

> "A distributed lock is a lie unless the resource it protects checks a fencing token." Paraphrasing Martin Kleppmann.

## Why distributed locks are hard

Locally, if a thread holding a lock dies, the process dies with it and the lock is gone. In a distributed system:
- The lock holder can **crash** while holding the lock, so locks need **expiry (leases)**.
- The lock holder can **pause** (GC, VM migration, page fault, CPU starvation) for longer than the lease. The lease expires, someone else gets the lock, the original holder wakes up **still believing it holds the lock**, and now two holders exist.
- **Clocks drift**, so lease expiry measured on different machines disagrees.
- **Network delays:** a "grant" message can arrive after the lease has already expired.

## Two purposes for locks (decide which you need)

1. **Efficiency:** avoid doing the same work twice (for example, two cron instances sending the same report). An occasional double execution is tolerable. **A simple Redis lock is fine.**
2. **Correctness:** two holders would corrupt data (two writers to the same file, double charge). **You need consensus-backed locks plus fencing tokens**, or better, design so the resource itself enforces the exclusivity.

## Leases

A **lease** is a lock with a time limit. The holder must renew (heartbeat) before expiry.
- Lease too short: false expirations under load or GC.
- Lease too long: slow recovery after a crash.
- Typical: 10–30s, with renewal every TTL/3.
- **The holder must stop work if it can't renew before expiry, measured on its own clock with a safety margin.** It still can't fully protect against pauses, which is why fencing exists.

## The GC pause problem

```
Client 1: acquire lock (lease 10s)
Client 1: ---- GC pause 15s ----
          lease expires
Client 2: acquire lock
Client 2: write to storage
Client 1: wakes up, thinks it holds the lock, writes to storage   ← CORRUPTION
```

## Fencing tokens: the fix

The lock service returns a **monotonically increasing token** with each grant. The **protected resource** remembers the highest token it has seen and rejects lower ones.

```
Client 1: acquire → token 33
Client 1: GC pause...
Client 2: acquire → token 34
Client 2: write(token=34)  → storage accepts, max_token = 34
Client 1: write(token=33)  → storage REJECTS (33 < 34)
```

Sources of fencing tokens:
- ZooKeeper: `zxid` or the znode's version / sequential node number
- etcd: the key's `mod_revision` or the lease's revision
- A DB sequence
- Raft: term number (leader epochs are fencing tokens)

**Requirement:** the resource must check tokens. If you're writing to a system that can't (an S3 bucket, a third-party API), you need another approach: idempotency keys or conditional writes on the resource itself.

**Generalization:** **epoch numbers** used throughout distributed systems (Raft terms, Kafka controller epoch, leader epochs in Kafka partitions, ZAB epochs) are fencing tokens. They stop "zombie" old leaders from acting.

## Implementations

### 1. Redis single-instance lock
```
SET lock:resource <random_value> NX PX 30000     # acquire
-- release only if we own it (atomic via Lua):
if redis.call("GET", KEYS[1]) == ARGV[1] then
    return redis.call("DEL", KEYS[1])
else return 0 end
```
- The **random value** ensures you only delete your own lock (not one re-acquired by someone else after your lease expired).
- **Problem:** Redis replication is async. The primary grants the lock, crashes before replicating, the replica is promoted, and another client acquires the same lock.
- **Good for efficiency locks. Not for correctness.**

### 2. Redlock (Redis, N independent masters)
- Acquire on a majority (e.g., 3 of 5) of independent Redis nodes within a time bound.
- **Controversial.** Kleppmann's critique: it relies on timing assumptions (bounded clock drift, bounded pauses) and provides **no fencing token**. Antirez (Redis author) disagrees.
- Interview stance: "Redlock is still timing-dependent and has no fencing, so for correctness-critical locks I'd use a consensus system like etcd or ZooKeeper with fencing tokens."

### 3. ZooKeeper
- Create an **ephemeral sequential** znode `/locks/res/lock-0000000042`.
- The lowest sequence number holds the lock. Others **watch the node just before theirs** (not the lowest, to avoid a herd effect).
- Ephemeral nodes vanish when the session expires (client crash or partition).
- Sequence number and zxid give you a fencing token.
- Linearizable writes through ZAB consensus.

### 4. etcd
- Create a key with a lease: `Put(key, val, WithLease(leaseID))` in a transaction `If(CreateRevision(key) == 0)`.
- `concurrency.Mutex` in the Go client implements a fair queue by revision.
- Lease keepalives; when the lease expires the key is deleted.
- `mod_revision` works as a fencing token.
- Raft-backed, linearizable.

### 5. Database locks
- **Row lock** (`SELECT ... FOR UPDATE` on a locks table), **advisory locks** (Postgres), or a **lease row**:
  ```sql
  UPDATE leases SET owner=:me, expires_at=now()+interval '30s', token=token+1
  WHERE name='job-x' AND (expires_at < now() OR owner=:me)
  RETURNING token;
  ```
  The `token` column is the fencing token. Simple and often good enough if you already have a strongly consistent DB.

### 6. Chubby (Google)
- The original lock service (paper, 2006). Paxos-based, coarse-grained, long-lived locks with **sequencers** (fencing tokens). Mostly used for leader election and storing small metadata. Bigtable and GFS used it.

## Comparison

| | Redis (single) | Redlock | ZooKeeper | etcd | DB lease row |
|---|---|---|---|---|---|
| Safety under failover | ❌ | Debated | ✅ | ✅ | ✅ (if DB is CP) |
| Fencing token | Manual | ❌ | ✅ | ✅ | ✅ |
| Latency | ~1ms | ~few ms | ~few ms (quorum write) | ~few ms | ~few ms |
| Throughput | Very high | High | Moderate | Moderate | Moderate |
| Use for | Efficiency, dedup | Efficiency | Correctness, leader election | Correctness, leader election (K8s) | Correctness when DB exists |

## Leader election = a distributed lock

- "The lock holder is the leader."
- Followers watch the lock and take over when it's released or expires.
- **Always pair with fencing (epoch/term)** so the old leader's late writes are rejected.
- Kubernetes uses a Lease object in etcd for controller leader election.

## Better than a lock: avoid needing one

Ask first: **can I eliminate the lock?**

| Instead of a lock... | Use... |
|---|---|
| Lock to prevent duplicate processing | Idempotency key + unique constraint |
| Lock to serialize writes on a key | Partition by key; single consumer per partition (Kafka) |
| Lock around read-modify-write | Atomic conditional write (CAS, `UPDATE ... WHERE version=?`) |
| Lock for one-active-instance cron | Lease row with fencing, or a scheduler with exactly-one semantics |
| Lock to merge concurrent edits | CRDTs / OT |

## Interview answer template

> "I need mutual exclusion for X. If it's only for efficiency, a Redis `SET NX PX` lock with a random owner value is enough. Worst case, we do the work twice. Here it's correctness-critical, so I'll take a lease in etcd and pass its revision as a fencing token to the storage layer, which rejects writes with stale tokens. That protects us from a holder that pauses past its lease. Even better: can we make the operation idempotent so a duplicate holder is harmless?"
