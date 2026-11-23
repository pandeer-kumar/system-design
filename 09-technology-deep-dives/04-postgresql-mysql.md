# PostgreSQL and MySQL Internals: A Deep Dive

> Relational databases are the default system of record. FAANG interviewers probe how they actually behave: how MVCC works, why VACUUM matters, what a replica can lose, what locks a statement takes, and how far one box goes before you shard.

## 1. PostgreSQL architecture

```
client ──► postmaster (forks) ──► one backend PROCESS per connection
                                     │
            shared memory: shared_buffers (page cache), WAL buffers, lock table, proc array
                                     │
background processes: WAL writer, checkpointer, background writer, autovacuum launcher/workers,
                      WAL sender(s) (replication), stats, logical replication workers
```

- **Process per connection** (~5–10 MB each). Thousands of connections hurt (memory, context switches, snapshot computation cost grows with connection count). **Use a pooler (PgBouncer)**; aim for a few hundred server connections at most.
- **Double buffering:** Postgres has `shared_buffers` (typically ~25% of RAM) *and* relies on the OS page cache for the rest.
- Data files are 8 KB **pages** (heap tables are unordered; indexes are separate structures pointing at heap tuple IDs, the **TID/ctid** = (page, slot)).

## 2. MVCC in Postgres (the key to almost everything)

Every row version (**tuple**) has hidden columns:

- `xmin`: the transaction ID that created this version
- `xmax`: the transaction ID that deleted/updated it (0 if live)

**UPDATE = INSERT a new tuple + set `xmax` on the old one.** Nothing is overwritten in place.

```
UPDATE accounts SET balance = 300 WHERE id = 1;   (by txid 105)
  old tuple: xmin=100, xmax=105, balance=500
  new tuple: xmin=105, xmax=0,   balance=300
```

**Visibility:** each statement (Read Committed) or transaction (Repeatable Read) takes a **snapshot**: `xmin_horizon`, `xmax`, and the list of in-progress transaction IDs. A tuple is visible if its `xmin` committed before the snapshot and its `xmax` is absent, aborted, or not yet committed in that snapshot. Commit status lives in the **CLOG** (commit log); **hint bits** cache it on the tuple after first check.

### Consequences you should be able to explain

1. **Readers never block writers, and writers never block readers.**
2. **Dead tuples accumulate** → table and index **bloat** → `VACUUM` must reclaim them.
3. **Long-running transactions are dangerous:** an open transaction (or an idle-in-transaction session, or a stale replication slot) holds back the cleanup horizon, so VACUUM can't remove anything newer, and bloat grows everywhere.
4. **Every UPDATE touches every index** (the new tuple has a new TID), **unless it's a HOT update**: if no indexed column changed and the new tuple fits on the same page, Postgres chains it there and skips index updates. Leave free space (`fillfactor` 70–90) on update-heavy tables.
5. **Write amplification** on wide tables with many indexes (this is why Uber famously moved some workloads from Postgres to MySQL in 2016).

### VACUUM and autovacuum

- `VACUUM` marks dead tuples' space reusable (doesn't shrink the file), updates the **visibility map** (enables index-only scans) and the free space map.
- `VACUUM FULL` rewrites the table (takes an exclusive lock; avoid in production; use `pg_repack`).
- **Autovacuum** triggers on `dead tuples > threshold + scale_factor × rows`. On huge, hot tables the default 20% scale factor is far too lazy; set per-table thresholds.

### Transaction ID wraparound (a real outage class)

- Transaction IDs are 32-bit and compared circularly. Old tuples must be **frozen** (marked "visible to everyone") before 2 billion transactions pass, or they'd appear to be in the future.
- If freezing falls behind, Postgres **stops accepting writes** to prevent data corruption. (Sentry's 2015 outage and several others.)
- Prevent it: healthy autovacuum, no long transactions, and monitor `age(datfrozenxid)`.

## 3. WAL, checkpoints, and durability

- Every change is written to the **WAL** (write-ahead log) before data pages. On commit, the WAL is flushed (`fsync`) → durable.
- **Group commit:** concurrent commits share one fsync.
- `synchronous_commit = off`: commits return before the WAL flush (risk: lose the last ~600 ms on crash, but no corruption). A good trade-off for low-value writes.
- **Checkpoints** flush dirty pages so crash recovery replays only WAL since the last checkpoint. The first change to a page after a checkpoint writes a **full page image** into the WAL (protects against torn pages), which causes WAL spikes right after checkpoints.
- **Crash recovery = replay WAL from the last checkpoint.**

## 4. Indexes

| Type | Use |
|---|---|
| **B-tree** (default) | Equality, ranges, sorting, prefix `LIKE 'abc%'` |
| Hash | Equality only (rarely better than B-tree) |
| **GIN** | Many values per row: full-text (`tsvector`), JSONB containment, arrays, trigram search |
| **GiST** / SP-GiST | Geometry (PostGIS), ranges, nearest-neighbour, **exclusion constraints** (no overlapping bookings) |
| **BRIN** | Huge append-only tables where values correlate with physical order (time series). Tiny index. |
| HNSW / IVFFlat (pgvector) | Vector similarity |

Features worth naming:

- **Composite index** column order: equality columns first, then range/sort columns.
- **Covering index** (`INCLUDE (col)`) → index-only scans (if the visibility map is up to date).
- **Partial index** (`WHERE status = 'pending'`) for queues and soft deletes.
- **Expression index** (`lower(email)`).
- **`CREATE INDEX CONCURRENTLY`** to avoid blocking writes.
- **Exclusion constraint** for "no two bookings overlap for the same room":
    ```sql
    ALTER TABLE bookings ADD CONSTRAINT no_overlap
      EXCLUDE USING gist (room_id WITH =, tstzrange(start_at, end_at) WITH &&);
    ```
    This is the clean answer to the phantom/write-skew double-booking problem.

## 5. Locks

**Row-level:** Postgres records a row lock by setting `xmax` (and multixact IDs for shared locks), not in the lock table, so millions of row locks cost little memory.

| Statement | Row lock |
|---|---|
| `UPDATE`, `DELETE` | FOR UPDATE (exclusive) on affected rows |
| `SELECT ... FOR UPDATE` | Exclusive |
| `SELECT ... FOR NO KEY UPDATE` | Weaker: doesn't block FK inserts referencing the row |
| `SELECT ... FOR SHARE` / `FOR KEY SHARE` | Shared |
| `... NOWAIT` / `SKIP LOCKED` | Fail fast / skip |

**Table-level** (selected): `ACCESS SHARE` (SELECT) conflicts only with `ACCESS EXCLUSIVE`. `ROW EXCLUSIVE` (DML). `ACCESS EXCLUSIVE` (`ALTER TABLE`, `DROP`, `VACUUM FULL`) blocks everything.

**The classic migration outage:** `ALTER TABLE` waits for an ACCESS EXCLUSIVE lock behind a long-running query; every new query then queues **behind the ALTER**, and the app freezes. Always set `lock_timeout` (e.g., 2 s) for DDL and retry.

**Advisory locks:** `pg_advisory_lock(key)` / `pg_try_advisory_xact_lock(key)` for application-level mutual exclusion (one migration runner, one cron leader). Note that PgBouncer in transaction mode breaks session-level advisory locks; use transaction-level ones.

**Deadlocks:** detected after `deadlock_timeout` (1 s); one transaction is aborted with `40P01`. Retry it.

## 6. Isolation levels in Postgres specifically

| Level | Implementation | Notes |
|---|---|---|
| Read Committed (default) | New snapshot per **statement** | Lost updates possible in read-modify-write app code. A concurrent `UPDATE` re-checks the `WHERE` on the newest row version (EvalPlanQual). |
| Repeatable Read | **Snapshot isolation**: one snapshot per transaction | Concurrent update to the same row → `40001 could not serialize`, retry. Write skew still possible. |
| Serializable | **SSI** (predicate locks tracking rw-dependencies) | Prevents write skew; aborts with `40001` on dangerous structures. Retry loop required. |

## 7. Query planning (what to say when "the query is slow")

- Cost-based planner using table **statistics** (`ANALYZE`: histograms, most-common values, n_distinct, correlation).
- `EXPLAIN (ANALYZE, BUFFERS)`: compare estimated vs actual rows. Big misestimates mean stale or insufficient statistics (raise `default_statistics_target`, or use extended statistics for correlated columns).
- Join methods: nested loop (small inputs, index on the inner side), hash join (large, equality), merge join (sorted inputs).
- Common fixes: missing or wrong-order composite index, function on an indexed column (`WHERE date(created_at) = ...`), implicit casts, `OFFSET` pagination (switch to keyset), `SELECT *` defeating index-only scans, N+1 queries from the ORM.

## 8. Replication and high availability

### Physical (streaming) replication

- Replicas replay the primary's WAL byte-for-byte (same major version required). Read-only **hot standbys**.
- **Async by default:** a failover can lose the most recent commits.
- **Synchronous:** `synchronous_standby_names = 'ANY 1 (s1, s2)'` (quorum commit). `synchronous_commit` levels: `remote_write` (in standby OS memory), `on` (flushed on standby), **`remote_apply`** (applied, so reads on the standby see it: read-your-writes on replicas).
- **Replica query conflicts:** VACUUM on the primary can remove rows a long query on the standby still needs → the query is canceled, or with `hot_standby_feedback=on` the primary keeps them (bloat).
- **Replication slots** guarantee WAL is retained until a consumer reads it. **A dead slot retains WAL forever and fills the primary's disk.** Monitor slot lag; set `max_slot_wal_keep_size`.

### Logical replication / CDC

- Decodes WAL into row changes (`pgoutput`, `wal2json`); publications and subscriptions; cross-version upgrades; selective tables. **Debezium** uses this for CDC to Kafka.

### HA / failover

- Postgres has no built-in automatic failover. Use **Patroni** (leader key in etcd/Consul/ZooKeeper with a TTL; the holder is primary; others follow; fencing by losing the key → demote), or managed services (RDS Multi-AZ, Aurora, Cloud SQL, AlloyDB).
- **Aurora:** compute nodes ship only WAL (redo) to a distributed storage layer replicated 6 ways across 3 AZs (write quorum 4/6). Replicas share the storage (lag in ms), failover in ~30 s or less, and storage grows automatically.

## 9. Scaling Postgres

1. Tune: indexes, queries, `work_mem`, autovacuum, connection pooling.
2. **Vertical:** single instances handle tens of thousands of TPS and tens of TB.
3. **Read replicas** (with read-your-writes handling).
4. **Partitioning** (declarative, by range/list/hash): partition pruning, cheap retention (`DROP` an old partition instead of a huge `DELETE`), smaller indexes. Not sharding: still one node.
5. **Sharding:** application-level by tenant/user ID; **Citus** (distributed tables with a coordinator); or move hot workloads to purpose-built stores.
6. **Distributed SQL** with the Postgres wire protocol: CockroachDB, YugabyteDB, AlloyDB/Aurora (scale-up storage), Aurora DSQL.

## 10. MySQL (InnoDB): the important differences

| Topic | PostgreSQL | MySQL InnoDB |
|---|---|---|
| Table storage | Heap (unordered); indexes point to TID | **Clustered index**: rows stored in PK order inside the B+tree; secondary indexes store the **PK** (so a secondary lookup = two B-tree traversals) |
| PK choice | Less critical | **Critical:** random UUID PKs cause page splits and poor locality → use auto-increment or time-ordered IDs |
| MVCC old versions | Stored in the table (dead tuples → VACUUM) | Stored in **undo logs**; rows updated in place; purge thread cleans undo. Long transactions bloat the undo (history list length). |
| Default isolation | Read Committed | **Repeatable Read** (consistent snapshot for plain SELECTs; locking reads and UPDATEs see the latest committed data) |
| Phantom protection | SSI at Serializable | **Gap and next-key locks** on locking reads/updates in RR. Prevents phantoms, but causes surprising deadlocks and lock waits on range conditions. |
| Logs | WAL | **Redo log** (InnoDB crash recovery) + **binlog** (server-level, for replication/CDC), kept consistent by an internal 2PC |
| Replication | Physical WAL streaming; logical decoding | **Binlog** (row-based recommended), async by default; **semi-sync** (wait for ≥1 replica to receive); **Group Replication / InnoDB Cluster** (Paxos-based) |
| Connections | Process per connection | Thread per connection (cheaper; thread pool in some editions) |
| Online DDL | Many DDLs fast; `CONCURRENTLY` for indexes | Online DDL (INPLACE/INSTANT); **gh-ost** / pt-online-schema-change for big tables |
| Sharding ecosystem | Citus | **Vitess** (YouTube, Slack, GitHub), ProxySQL |
| Features | Richer: JSONB + GIN, extensions (PostGIS, pgvector), exclusion constraints, partial indexes | Simpler, very mature at large scale |

## 11. Interview questions

1. **What happens on UPDATE in Postgres?** A new tuple version is written, the old one gets `xmax`; indexes get new entries unless it's a HOT update; the old tuple becomes dead after no snapshot needs it, and VACUUM reclaims it.
2. **Why are long-running transactions bad?** They hold back the MVCC cleanup horizon → bloat, slower queries, and in extremes transaction ID wraparound risk; on MySQL they grow the undo history.
3. **What's transaction ID wraparound?** 32-bit XIDs require freezing old tuples; if freezing falls behind, Postgres stops writes to avoid corruption.
4. **How do you prevent two overlapping bookings?** Exclusion constraint with GiST on the time range, or materialized slots with a unique constraint, or serializable isolation.
5. **Why use PgBouncer?** Process-per-connection makes thousands of connections expensive; transaction pooling multiplexes many clients onto few server connections. (Caveats: session state, prepared statements in older versions, session advisory locks.)
6. **Can a Postgres failover lose data?** Yes with async replication. Use synchronous quorum commit for RPO 0, at the cost of latency, and fence the old primary.
7. **Why is a random UUID primary key bad in MySQL?** The clustered index orders rows by PK; random inserts split pages all over the B-tree and destroy cache locality. Use time-ordered IDs (UUIDv7, Snowflake).
8. **How do gap locks cause deadlocks?** Two transactions take gap locks on the same range (allowed, since gap locks don't conflict with each other), then both try to insert into it → each waits for the other's gap lock.
9. **How do you run a migration on a 1 TB hot table?** Expand/contract; online tools (gh-ost, pg_repack, `CONCURRENTLY`); `lock_timeout` on DDL; batch backfills with throttling.
10. **When do you shard?** When write throughput, data size, or vacuum/backup times exceed one primary after optimization and vertical scaling; choose a shard key that keeps transactions single-shard.
