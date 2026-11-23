# Case Study 16: File Sync and Storage (Dropbox / Google Drive)

> Tests: chunking and dedup, metadata vs blob separation, the sync protocol, concurrent edit conflicts, and bandwidth efficiency.

## 1. Requirements

**Functional**
- Upload/download files; sync across a user's devices automatically
- Share files and folders with others
- Version history; restore deleted files
- Offline edits sync later

**Non-functional**
- 500M users, 100M DAU; files up to 50 GB
- Sync latency: seconds after a change
- **Never lose data**; handle conflicts gracefully
- Bandwidth-efficient (only upload changed parts)

## 2. Key idea: chunking + content addressing

- Split files into chunks (~4 MB fixed, or **content-defined chunking** with rolling hashes (Rabin fingerprints) so an insert near the start doesn't shift all later chunk boundaries).
- Each chunk is identified by its **SHA-256 hash**, stored once in blob storage (**dedup across all users**).
- A file = an ordered list of chunk hashes (a manifest). Editing a file changes a few chunks, so only those are uploaded.

## 3. Architecture

```
Client (watcher, chunker, local DB of file state, sync engine)
   ├── Metadata Service (API) ──> Metadata DB (sharded MySQL/Postgres by namespace/user)
   │       files(namespace_id, path, file_id, latest_version, ...)
   │       file_versions(file_id, version, chunk_list[], size, modified_by, ts)
   │       journal(namespace_id, seq, change)  ← ordered change log per namespace
   ├── Block Service ──> Blob storage (S3 / custom like Dropbox Magic Pocket), keyed by chunk hash
   └── Notification Service (long poll / WebSocket): "namespace X has changes after seq N"
```

## 4. Upload flow

1. The client detects a change (file system watcher), chunks the file, and hashes the chunks.
2. Asks the metadata service: "which of these hashes do you not have?" (`/check_blocks`)
3. Uploads only the missing chunks to the block service (directly to blob storage with pre-signed URLs).
4. **Commits** the new version: `commit(file_id, base_version=V, chunk_list)`, which is conditional on the current version being V (**optimistic concurrency**).
5. The server appends to the namespace **journal** (seq N+1) and notifies other devices.

## 5. Download / sync flow

- Each device stores a **cursor** (last journal seq seen) per namespace.
- The notification service tells devices "new changes" (long poll returns). The device calls `list_changes(cursor)`, gets the changes, and downloads the missing chunks.
- The journal gives an **ordered, replayable** change feed per namespace. That's the same pattern as chat sync from a cursor.

## 6. Deep dive: conflicts

Two devices edit the same file offline.
- Device A commits version 6 (base 5). Device B tries to commit with base 5 → **conflict** (current is 6).
- Resolution: **don't merge binary files.** Keep both: save B's version as "file (B's conflicted copy).docx". That's what Dropbox does: no data loss, and the user decides.
- For specific types (Google Docs), real-time collaboration avoids conflicts (see [12-collaborative-editor.md](12-collaborative-editor.md)).
- Folder operations (rename/move) racing with edits: model files by a stable **file_id**, not path, so a rename is a metadata change.

## 7. Deep dive: metadata consistency

- The metadata DB is the source of truth and needs **strong consistency** per namespace (journal sequence, version checks).
- Shard by **namespace** (user root or shared folder), so a namespace's operations are single-shard transactions.
- Shared folders are their own namespace and are mounted into each member's tree.
- Dropbox's Edgestore and its later work on sync engine correctness (the "Nucleus" rewrite in Rust) are good reading.

## 8. Blob storage

- Content-addressed chunks: immutable, so caching is easy, and they're verifiable with checksums.
- **Garbage collection:** a chunk can be deleted only when no file version references it. Use reference counting (with care under concurrency) or periodic mark-and-sweep, with a grace period, because an upload in progress may reference a chunk that isn't committed yet.
- Erasure coding for cold data; replication for hot.
- **Encryption:** per-chunk encryption; with convergent encryption, dedup still works (with known privacy trade-offs).

## 9. Bandwidth and performance

- Delta sync (only changed chunks); compression; LAN sync (peers on the same network share chunks).
- Prioritize small files and recent changes; throttle background uploads.
- Large file uploads: parallel chunks, resumable.

## 10. Failure modes

| Failure | Handling |
|---|---|
| Upload interrupted | Chunks already uploaded remain (content-addressed); resume by re-checking missing hashes |
| Commit after chunks uploaded fails | Retry the commit (idempotent with a client-generated commit ID); orphan chunks are garbage collected |
| Notification lost | Periodic polling of `list_changes(cursor)` as a backstop |
| Client bug corrupts local state | Server is the source of truth; re-sync from the journal; version history allows restores |

## 11. Follow-ups

- **Sharing permissions:** ACLs per namespace; link sharing with tokens.
- **Search across files:** content extraction → search index (asynchronously).
- **Quotas:** account size computed from version metadata; deduped chunks count fully per user (logical size) even if physically shared.
