# Conflict Resolution and CRDTs

When replicas accept writes independently (multi-leader, leaderless, offline clients), concurrent writes **conflict**. You must resolve them deterministically so all replicas converge.

## Conflict resolution strategies

| Strategy | Description | Data loss? | Example |
|---|---|---|---|
| **Last-writer-wins (LWW)** | Highest timestamp wins | **Yes**, silently | Cassandra, DynamoDB Global Tables |
| **Siblings / multi-value** | Keep all concurrent versions; reader merges | No | Dynamo, Riak |
| **Application merge** | Custom function (e.g., union carts) | Depends | Dynamo shopping cart |
| **Operational transformation** | Transform concurrent ops against each other | No | Google Docs |
| **CRDTs** | Data types designed to merge without conflicts | No (by design) | Riak data types, Redis Enterprise CRDB, Automerge, Yjs |
| **Avoid** | Route writes per key to one home leader | N/A | Most practical multi-region designs |

**Dynamo's shopping cart lesson:** merging by union means deleted items can **reappear** (a delete in one replica, concurrent with an add in another). That's acceptable for carts; it's not acceptable in general. Proper CRDTs (OR-Set) fix this.

## CRDTs (Conflict-free Replicated Data Types)

A CRDT guarantees **strong eventual consistency**: replicas that have received the same set of updates are in the same state, regardless of order or duplication.

### Two families
- **State-based (CvRDT):** replicas send their whole state; merge = **join** in a semilattice (commutative, associative, idempotent). Tolerates duplicates and reordering. Larger messages (delta-CRDTs mitigate this).
- **Operation-based (CmRDT):** replicas send operations; operations must commute; requires reliable causal delivery (exactly-once, causal order).

### Common CRDTs

#### G-Counter (grow-only counter)
Each replica `i` has its own slot `P[i]`. Increment: `P[self]++`. Value: `sum(P)`. Merge: element-wise `max`.
```
A: {A:3, B:0}   B: {A:1, B:5}   merge → {A:3, B:5} = 8
```

#### PN-Counter (increment and decrement)
Two G-Counters: P (increments) and N (decrements). Value = sum(P) − sum(N).
**Caveat:** can't enforce invariants like "≥ 0" (two replicas can both decrement the last item). **Inventory needs coordination, not just CRDTs.** Bounded counters / escrow (pre-allocate quota per replica) are the workaround.

#### G-Set (grow-only set)
Add only. Merge = union.

#### 2P-Set (two-phase set)
An add set plus a remove set (tombstones). Once removed, it can never be re-added.

#### LWW-Element-Set
Each element has add and remove timestamps; the higher one wins. Simple, but has clock issues.

#### OR-Set (Observed-Remove Set): the important one
- Each add gets a **unique tag**. Remove deletes only the tags **observed** at the remover.
- Concurrent add and remove: **add wins** (the new tag wasn't observed by the remove).
- This fixes the Dynamo cart resurrection problem correctly.

#### LWW-Register, MV-Register
- LWW-Register: one value, latest timestamp wins.
- MV-Register (multi-value): keeps all concurrent values (like Dynamo siblings).

#### Sequence CRDTs (for text editing)
- **RGA, Logoot, LSEQ, Treedoc, YATA (Yjs), Fugue:** each character gets a unique, ordered ID, so concurrent inserts at the same position are ordered deterministically.
- Used by Yjs, Automerge, and many collaborative editors.
- Challenges: metadata overhead (IDs per character, tombstones), interleaving anomalies (fixed by Fugue).

#### Map CRDTs, JSON CRDTs
Nested CRDTs (Automerge provides a JSON CRDT).

### CRDT costs and limits
- **Metadata growth:** tombstones and per-replica entries. Garbage collection needs coordination (all replicas have seen the delete).
- **Can't enforce global invariants** (uniqueness, non-negative balance), because those need coordination. The CALM theorem: **monotonic** programs don't need coordination; non-monotonic ones (involving negation or thresholds) do.
- Semantics may surprise users (add-wins vs remove-wins choices).

## Operational Transformation (OT)

- Operations (insert at position, delete at position) are **transformed** against concurrent operations so intent is preserved.
- Example: A inserts "x" at 0; B concurrently deletes position 3. When A's op arrives at B, B applies it as-is; when B's delete arrives at A, A shifts it to position 4.
- Correct OT with many peers is notoriously hard. **Google Docs uses a central server** to impose a total order (Jupiter protocol), which simplifies it.
- See [06-case-studies/12-collaborative-editor.md](../06-case-studies/12-collaborative-editor.md).

## OT vs CRDT

| | OT | CRDT |
|---|---|---|
| Topology | Usually needs a central server | Peer-to-peer, offline-friendly |
| Complexity | Transform functions are tricky | Data structure design is tricky |
| Metadata | Small | Larger (IDs, tombstones) |
| Production | Google Docs, Office Online | Figma (CRDT-inspired, server-authoritative), Yjs/Automerge apps, Apple Notes, Linear |

## Practical guidance

1. **First choice: avoid conflicts.** A single home region per entity, or a single writer.
2. **If conflicts are inevitable and merge semantics are clear:** use CRDTs (counters, sets, presence, collaborative text).
3. **If you must use LWW:** use it only for data where losing a concurrent write is acceptable, and use **hybrid logical clocks**, not raw wall clocks.
4. **For invariants (stock ≥ 0, unique usernames):** you need coordination, either a single leader or consensus. Or **escrow**: split the quota across replicas ahead of time (replica A can sell 50, B can sell 50) and rebalance occasionally.
