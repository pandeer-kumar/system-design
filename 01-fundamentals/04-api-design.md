# API Design for System Design Interviews

## Principles

1. **Model resources around access patterns**, not database tables.
2. **Be explicit about consistency and idempotency** in the contract.
3. **Version from day one** (`/v1/`) and design for backward compatibility.
4. **Don't let a client cause unbounded work.** Paginate, cap limits, and set timeouts.

## REST conventions

```
GET    /v1/users/{id}              read
GET    /v1/users/{id}/orders?limit=50&cursor=abc   list
POST   /v1/orders                  create (NOT idempotent by default → needs Idempotency-Key)
PUT    /v1/orders/{id}             full replace (idempotent)
PATCH  /v1/orders/{id}             partial update
DELETE /v1/orders/{id}             delete (idempotent)
```

| Method | Safe | Idempotent |
|---|---|---|
| GET, HEAD | ✅ | ✅ |
| PUT, DELETE | ❌ | ✅ |
| POST, PATCH | ❌ | ❌ (unless you make them idempotent) |

### Status codes that matter
- `200/201/202` (202 Accepted = async processing, return a job ID)
- `400` bad input, `401` unauthenticated, `403` unauthorized, `404`, `409 Conflict` (version mismatch, duplicate), `412 Precondition Failed` (If-Match failed)
- `429 Too Many Requests` (+ `Retry-After`)
- `500`, `502` bad gateway, `503` unavailable (+ `Retry-After`), `504` gateway timeout

**Retry policy:** retry `429`, `503`, `504`, and connection errors with backoff. Don't retry `4xx` (other than 408/429). **Retrying a POST after a timeout is only safe with an idempotency key.**

## Idempotency keys

```
POST /v1/payments
Idempotency-Key: 7c9e6679-7425-40de-944b-e07fc1f90ae7
```
The server stores `(key → request hash, response)` for ~24h. A duplicate key returns the stored response. The same key with a different body returns `422`. A concurrent duplicate while the first is in flight returns `409`. Full details in [02-concurrency/06-idempotency.md](../02-concurrency/06-idempotency.md).

## Optimistic concurrency in APIs

```
GET /v1/docs/42           → ETag: "v17"
PUT /v1/docs/42
If-Match: "v17"           → 200 if still v17, else 412 Precondition Failed
```
This prevents **lost updates** when two clients edit the same resource.

## Pagination

| Type | How | Pros | Cons |
|---|---|---|---|
| Offset | `?offset=1000&limit=50` | Simple, jump to page N | `OFFSET` scans skipped rows (slow at depth); inserts shift results, causing duplicates or skips |
| Cursor / keyset | `?cursor=<opaque(last_id, last_ts)>` | O(log n) seek, stable under inserts | No random page jumps |

Use **cursor-based pagination** for feeds and large lists:
```sql
SELECT * FROM posts
WHERE (created_at, id) < (:last_ts, :last_id)
ORDER BY created_at DESC, id DESC
LIMIT 50;
```
Make cursors **opaque** (base64-encoded, ideally signed) so you can change the implementation later.

## Long-running operations

```
POST /v1/videos → 202 Accepted { "job_id": "j123", "status_url": "/v1/jobs/j123" }
GET  /v1/jobs/j123 → { "status": "processing", "progress": 0.4 }
```
Alternatively, a webhook or callback when done, or SSE/WebSocket for progress.

## Webhooks (outbound) design

- Sign payloads (HMAC with a shared secret, timestamp included to prevent replay).
- **At-least-once delivery** with retries and exponential backoff over hours or days.
- Receivers must dedupe by event ID.
- Include an event sequence number or timestamp, because delivery is unordered.
- Provide a "list events" API so receivers can reconcile what they missed.

## Rate limit headers

```
X-RateLimit-Limit: 1000
X-RateLimit-Remaining: 12
X-RateLimit-Reset: 1700000000
Retry-After: 30
```

## gRPC specifics

- Use **deadlines** and propagate them (if the caller has 200ms left, don't give a downstream call 1s).
- Status codes: `UNAVAILABLE` (retryable), `DEADLINE_EXCEEDED`, `RESOURCE_EXHAUSTED`, `ABORTED` (concurrency conflict, retry the transaction), `FAILED_PRECONDITION`.
- Backward compatibility: never reuse field numbers, and add new fields as optional.

## Batch APIs

Batching amortizes overhead (`POST /v1/events:batch` with up to 500 items). Return **per-item status**, because partial failure is the normal case.

## API design checklist for interviews

- [ ] Core endpoints with request and response shape
- [ ] Which calls are idempotent, and how non-idempotent ones become safe to retry
- [ ] Pagination strategy
- [ ] Auth (who's calling?) and authz (can they?)
- [ ] Rate limiting
- [ ] Sync vs async (202 + job)
- [ ] Versioning
