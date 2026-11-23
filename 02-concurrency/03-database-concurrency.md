# Database Concurrency: Isolation Levels, MVCC, and Anomalies

This is one of the most heavily tested areas for senior candidates. Know the anomalies by name, and know which isolation levels prevent which.

## ACID recap

- **Atomicity:** all or nothing (on crash or abort, roll back). Implemented with a WAL/undo log.
- **Consistency:** invariants hold (constraints, FKs). Partly the application's job.
- **Isolation:** concurrent transactions don't interfere (to the degree the isolation level promises).
- **Durability:** committed means it survives crashes (WAL fsync, replication).

## The anomalies

| Anomaly | What happens | Example |
|---|---|---|
| **Dirty write** | T2 overwrites T1's uncommitted write | Two transactions interleave writes to the same row; rollback becomes a mess |
| **Dirty read** | T2 reads T1's uncommitted write, then T1 aborts | You see a balance that never existed |
| **Non-repeatable read (fuzzy read)** | T1 reads a row twice and gets different values, because T2 committed in between | Report totals don't add up |
| **Phantom read** | T1 re-runs a range query and sees new or missing rows | `COUNT(*) WHERE doctor_on_call` changes |
| **Lost update** | Both read X, both write X+1, one update lost | Counter increments, inventory decrement |
| **Read skew** | T1 sees part of T2's changes (inconsistent snapshot across rows) | Transfer: you see the debit but not the credit |
| **Write skew** | Two transactions read overlapping data, write **different** rows, and together violate an invariant | Two doctors both go off-call because each saw the other on-call |

### Write skew (the one seniors must know)

Invariant: at least one doctor must be on call.
```
T1: SELECT count(*) FROM doctors WHERE on_call = true;  -- 2
T2: SELECT count(*) FROM doctors WHERE on_call = true;  -- 2
T1: UPDATE doctors SET on_call = false WHERE name = 'Alice';
T2: UPDATE doctors SET on_call = false WHERE name = 'Bob';
-- both commit → 0 doctors on call
```

- **Snapshot isolation does NOT prevent this.** The writes are to different rows, so there's no write-write conflict.
- Fixes: `SERIALIZABLE`, `SELECT ... FOR UPDATE` on the rows read, **materializing the conflict** (a row representing the constraint that both must update), or a DB constraint.

Other write-skew examples: double-booking a meeting room (two inserts into an empty time slot), username uniqueness without a unique index, overdrawing two accounts with a shared overdraft limit.

**Phantom-caused write skew** (booking an empty slot): there's no row to lock because you're checking that a row *doesn't* exist. Fixes: a unique constraint, an exclusion constraint (Postgres `EXCLUDE USING gist` for time ranges), materialized slot rows, predicate/range locks (serializable).

## Isolation levels

| Level | Dirty read | Non-repeatable | Phantom | Lost update | Write skew |
|---|---|---|---|---|---|
| Read Uncommitted | possible | possible | possible | possible | possible |
| **Read Committed** (Postgres/Oracle/SQL Server default) | ✅ prevented | possible | possible | possible | possible |
| **Repeatable Read** (MySQL InnoDB default) | ✅ | ✅ | InnoDB: mostly (gap locks); standard: possible | InnoDB: possible for plain reads | possible |
| **Snapshot Isolation** (Postgres "Repeatable Read") | ✅ | ✅ | ✅ (in snapshot) | ✅ (first-committer-wins) | **possible** |
| **Serializable** | ✅ | ✅ | ✅ | ✅ | ✅ |

**Gotchas:**

- Names lie. Postgres "Repeatable Read" is actually snapshot isolation. Oracle "Serializable" is actually snapshot isolation. MySQL "Repeatable Read" has subtle behaviour: plain `SELECT` reads the snapshot, but `UPDATE` sees the latest committed version.
- Read Committed, the most common default, **permits lost updates** for read-modify-write in application code.

## How databases implement isolation

### 1. Two-Phase Locking (2PL)

- Growing phase: acquire locks. Shrinking phase: release (strict 2PL releases at commit).
- Readers block writers and writers block readers.
- Gives serializability (with predicate or range locks for phantoms).
- Cons: low concurrency, deadlocks common.

### 2. MVCC (Multi-Version Concurrency Control)

- Every write creates a **new version** tagged with a transaction ID. Readers see a **snapshot** as of their start time (or statement start, for Read Committed).
- **Readers never block writers, and writers never block readers.**
- Write-write conflicts: under SI, "first committer wins" (the second one aborts with a serialization error) or row locks.
- Used by Postgres, MySQL InnoDB, Oracle, CockroachDB, Spanner, and most modern DBs.
- Costs: old versions must be cleaned up (Postgres `VACUUM`, InnoDB purge). **Long-running transactions block cleanup** and cause bloat. That's a real production issue.

```
Row "balance" versions:
  v1 (xmin=100, xmax=105) = 500
  v2 (xmin=105, xmax=∞)   = 300
Txn 103's snapshot sees v1 (500). Txn 110 sees v2 (300).
```

### 3. Serializable Snapshot Isolation (SSI)

- Postgres `SERIALIZABLE` and CockroachDB. MVCC plus tracking of read-write dependencies; aborts a transaction if a dangerous cycle (rw-antidependency structure) is detected.
- Optimistic: no blocking, but **aborts under contention, and the app must retry**.

### 4. Optimistic Concurrency Control (OCC)

- Read without locks, validate at commit that nothing you read changed, abort if it did. Good for low contention. (FoundationDB, many in-memory DBs.)

## Preventing lost updates: the 5 tools

1. **Atomic operations** (best when they fit):
    ```sql
    UPDATE products SET stock = stock - 1 WHERE id = 42 AND stock > 0;
    -- check affected rows: 0 means sold out
    ```
2. **Explicit locking:**
    ```sql
    SELECT stock FROM products WHERE id = 42 FOR UPDATE;
    -- app logic
    UPDATE products SET stock = :new WHERE id = 42;
    ```
3. **Optimistic version check (compare-and-set):**
    ```sql
    UPDATE products SET stock = :new, version = version + 1
    WHERE id = 42 AND version = :old_version;
    -- 0 rows affected → conflict → re-read and retry
    ```
4. **Higher isolation level** (SI detects lost updates in Postgres, aborting with a serialization failure).
5. **Single writer** (serialize all updates to a key through one queue partition or actor).

## Locking details

- **Row locks:** shared (S, `FOR SHARE`) vs exclusive (X, `FOR UPDATE`).
- **`SELECT ... FOR UPDATE NOWAIT`:** fail immediately if locked.
- **`SELECT ... FOR UPDATE SKIP LOCKED`:** skip locked rows. **The best primitive for a DB-backed job queue.** Each worker grabs different rows:
    ```sql
    SELECT id FROM jobs WHERE status='pending'
    ORDER BY created_at LIMIT 10
    FOR UPDATE SKIP LOCKED;
    ```
- **Gap and next-key locks (InnoDB):** lock ranges to prevent phantoms. Can cause surprising deadlocks.
- **Advisory locks (Postgres `pg_advisory_lock`):** application-defined locks keyed by an integer, for example a simple leader election or a "one migration at a time" guard.
- **Lock escalation (SQL Server):** many row locks become a table lock. Watch out with bulk updates.

## Practical guidance

| Scenario | Recommended approach |
|---|---|
| Counter / stock decrement | Atomic `UPDATE ... SET x = x - 1 WHERE x > 0` |
| Edit form with "someone else changed this" | Optimistic version column / ETag |
| Money transfer between accounts | `FOR UPDATE` with lock ordering, or serializable plus retry |
| Uniqueness (username, one booking per seat) | **Unique constraint**. Let the DB enforce it. |
| No-overlap time ranges (room booking) | Exclusion constraint, or materialized slots plus unique constraint |
| Invariants across rows (on-call doctors) | Serializable, or explicit locks on the rows read |
| Job queue in SQL | `FOR UPDATE SKIP LOCKED` |
| High-contention hot row | Don't. Shard the row, batch updates, or queue to a single writer. |

## Serializable retry loop (must do this right)

```python
for attempt in range(MAX_RETRIES):
    try:
        with db.transaction(isolation="SERIALIZABLE"):
            do_work()
        break
    except (SerializationFailure, DeadlockDetected):
        sleep(backoff_with_jitter(attempt))
else:
    raise TooMuchContention()
```
**Side effects inside the transaction** (sending email, calling APIs) are not rolled back on retry. Move them out (outbox pattern).

## Replication lag anomalies (read replicas)

These are concurrency problems too:

- **Read-your-writes violation:** a user updates their profile, refreshes, and the request hits a lagging replica, so the old profile shows. Fix: read from the primary for N seconds after a write, or track the user's last-write LSN and wait for the replica to catch up.
- **Monotonic reads violation:** consecutive reads hit different replicas and time goes backward. Fix: stick a user to one replica.
- **Consistent prefix violation:** you see an answer before the question (partitioned data replicated out of order).

See [03-distributed-systems/05-consistency-models.md](../03-distributed-systems/05-consistency-models.md).
