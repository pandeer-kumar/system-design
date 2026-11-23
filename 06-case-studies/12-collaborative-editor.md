# Case Study 12: Collaborative Editor (Google Docs / Figma / Notion)

> Tests: concurrent edits without locks, OT vs CRDT, real-time sync, presence, offline support, and the server's authoritative ordering.

## 1. Requirements

**Functional**

- Multiple users edit the same document concurrently, seeing each other's changes in real time
- Cursors and presence of other editors
- Version history, undo
- Offline editing with sync on reconnect
- Comments, permissions (view/comment/edit)

**Non-functional**

- Latency: local edits instant (optimistic); remote edits visible < 200ms
- **Convergence:** all users end up with the same document
- **Intent preservation:** concurrent edits don't clobber each other
- Durability: no lost edits
- Scale: millions of docs; most with 1–5 concurrent editors; some with 100+

## 2. Why naive approaches fail

- **Lock the document / paragraph:** terrible UX; locks held by disconnected users.
- **Last-writer-wins on the whole doc:** loses edits.
- **Send diffs and apply them:** positions shift under concurrent edits. A's "insert at 5" is wrong after B deleted characters 0–3.

## 3. Operational Transformation (Google Docs)

- Operations: `insert(pos, text)`, `delete(pos, len)`, plus formatting.
- When two ops are concurrent, **transform** one against the other so it applies correctly:
    ```
    Doc: "abc"
    A: insert(0, "X")   → "Xabc"
    B: delete(2, 1)     → "ab"    (deletes 'c')
    At A, B's op transforms to delete(3, 1) (shift because of A's insert) → "Xab"
    At B, A's op stays insert(0,"X") → "Xab"   ✅ converged
    ```
- **Central server ordering (Jupiter / Google Wave protocol):**
    - The server is the single source of truth with a **revision number**.
    - The client sends ops tagged with the revision they were based on.
    - The server transforms incoming ops against all ops committed since that revision, assigns the next revision, persists, and broadcasts.
    - Clients keep pending (unacked) ops and transform incoming server ops against them.
    - A client has at most one in-flight op batch at a time, which simplifies transformation.
- ✅ Compact ops, proven at scale. ❌ Requires a central server per document; transformation functions get complex for rich text.

## 4. CRDTs (Figma-inspired, Yjs, Automerge)

- Each character/element has a **unique, immutable ID** (e.g., `(site_id, counter)`) and a position defined relative to neighbours' IDs, not integer offsets.
- Inserts and deletes commute; any order of delivery converges.
- ✅ Works peer-to-peer and offline-first; the server can be a simple relay + persistence.
- ❌ Metadata overhead (IDs, tombstones), though modern implementations (Yjs) are very compact; garbage collection of tombstones.
- **Figma** uses a **server-authoritative** approach for its tree of objects: properties are LWW per (object, property) and the server orders updates. That's simpler than full text CRDTs, because design objects rarely have conflicting intent at the character level.

See [03-distributed-systems/08-crdts-conflict-resolution.md](../03-distributed-systems/08-crdts-conflict-resolution.md).

## 5. Architecture

```
Clients ──WebSocket──> Collaboration Gateway ──> Document Session Server (one owner per doc)
                                                   │  holds doc state in memory
                                                   │  orders/transforms ops (OT) or merges (CRDT)
                                                   │  broadcasts to all connected clients
                                                   ├── Op log (append-only: doc_id, revision, op) → durable store
                                                   └── Periodic snapshots (doc state at revision N) → blob store
Presence (cursors) via the same session, ephemeral, not persisted
```

### The key concurrency design: a single owner per document

- **Route all connections for a doc to the same session server** (consistent hashing on doc_id, or a lookup table/lease in a coordination service).
- The owner processes ops **sequentially** (single writer). No locks, a deterministic order.
- Ownership via a **lease with a fencing token**. If the owner dies, a new owner loads the latest snapshot + op log tail and clients reconnect. The op log write uses a conditional append (`revision = last + 1`), so a zombie owner can't append.

## 6. Persistence

- **Op log** per document: `(doc_id, revision) → op`, with a conditional append to guarantee no gaps or duplicates. Store in Bigtable/Cassandra/DynamoDB or Postgres.
- **Snapshots** every N ops or minutes. Load = snapshot + replay ops after it.
- **Version history** = snapshots + op log (named versions are pinned snapshots).
- Write ops to the log **before** acknowledging or broadcasting (durability), or acknowledge after a group commit every ~50ms (a trade-off).

## 7. Offline and reconnect

- The client keeps unacked ops locally (IndexedDB).
- On reconnect, it sends its last known server revision + pending ops. The server transforms them against everything since (OT), or merges (CRDT).
- Long offline periods with large divergence: CRDTs handle this more naturally; with OT, the server does a heavy transform (or rejects and the client rebases).

## 8. Presence and cursors

- Ephemeral, high-frequency, lossy is OK. Throttle to ~10–20 updates/s, sent via the session server.
- Cursor positions must be transformed too (or anchored to CRDT element IDs) so they stay correct as text changes.

## 9. Scaling

- Most docs are idle. Load the session lazily on first connect; evict after inactivity.
- Hot docs (100s of editors, or 10Ks of viewers): separate **viewers** (read-only fan-out via a broadcast tier/CDN of ops) from **editors** (through the owner). Batch broadcast (coalesce ops every 50ms).
- A document session is bounded by one server's CPU. That's fine for realistic editor counts.

## 10. Permissions and comments

- Permission check on WebSocket connect, plus re-validation on permission changes (push a revoke).
- Comments anchored to text ranges (by CRDT IDs or transformed positions); stored separately.

## 11. Failure modes

| Failure | Handling |
|---|---|
| Session server crash | New owner via lease; reload snapshot + op log; clients reconnect and resend unacked ops (idempotent by client op ID) |
| Split ownership (two servers think they own the doc) | Fencing token on op-log append: the conditional revision append fails for the stale owner |
| Client sends duplicate ops after reconnect | Dedupe by (client_id, client_seq) |
| Op log store slow | Backpressure; buffer in memory briefly; clients see "saving..." |

## 12. Follow-ups

- **OT or CRDT?** "A central server already exists for auth and persistence, so server-ordered OT (or server-ordered CRDT updates) keeps metadata small. If offline-first or peer-to-peer is a core requirement, CRDT (Yjs)."
- **Undo:** per-user undo of their own ops (an inverse op transformed against later ops).
- **Rich text / tables:** a tree-structured document model; ops on nodes (ProseMirror steps + OT on the server).
