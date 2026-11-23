# Case Study 05: Chat System (WhatsApp / Messenger / Slack)

> Tests: millions of persistent connections, message ordering, delivery guarantees, presence, group fan-out, and offline handling.

## 1. Requirements

**Functional**

- 1:1 and group chat (groups up to ~1,000; Slack channels larger)
- Online/offline delivery, message history across devices
- Delivery receipts (sent ✓, delivered ✓✓, read)
- Presence (online/last seen), typing indicators
- Media attachments

**Non-functional**

- 500M DAU, ~100M concurrent connections at peak
- Delivery latency < 200ms when both online
- **No message loss; no duplicates shown to the user; per-chat ordering**
- Highly available; multi-device

## 2. Estimation

- 20B messages/day ≈ 230K msgs/s avg, ~1M/s peak
- 100 bytes average → 2 TB/day of text
- 100M connections / ~500K per gateway server ≈ 200 servers (plan 400 for headroom and deploys)

## 3. Connection layer

- **WebSocket** (or MQTT, or a custom TCP protocol like WhatsApp's modified XMPP) from the client to a **chat gateway** (connection server).
- Gateways are stateful (they hold the sockets). Track **user → gateway** mapping in a **session/presence store** (Redis, sharded by user_id): `session:{user_id}:{device_id} → gateway_id`.
- Heartbeats every ~30s detect dead connections; mobile reconnects with **jittered backoff**.
- Gateways are kept thin (auth, framing, routing). Business logic lives in chat services.

## 4. High-level design

```
Sender ──WS──> Gateway A ──> Chat Service ──> Message Store (Cassandra/HBase, by conversation)
                                 │
                                 ├──> Sequencer (per conversation message_id)
                                 ├──> lookup recipients' gateways (Session store)
                                 ├──> route to Gateway B ──WS──> Recipient (online)
                                 └──> if offline → Push Notification Service (APNs/FCM)
                                       + message waits in the store for sync
```

Inter-gateway routing options:

- Chat service calls the target gateway directly via RPC (gateway address from the session store), or
- Publish to a **per-gateway queue/topic** (Kafka/Redis pub-sub keyed by gateway), which the gateway subscribes to.

## 5. Deep dive: message flow and delivery guarantees

**Send (client → server):**

1. Client generates a **client_msg_id** (UUID), shows the message as "sending."
2. Sends it over the WS. The server **persists it first** (dedupe by `(sender, client_msg_id)`), assigns a server `message_id`/sequence number, and acks to the sender ("sent ✓").
3. If there's no ack, the client retries with the **same client_msg_id**, so the server dedupes (idempotency).

**Deliver (server → recipient):**

1. Push to the online recipient's gateways (all of their devices).
2. The recipient's client acks receipt, and the server records **delivered**, notifying the sender (✓✓).
3. If no ack (or offline): the message stays in the store; when the client reconnects, it **syncs from its last-seen sequence number** per conversation (pull: `GET messages where conv=X and seq > last_seq`).

This gives **at-least-once delivery + client-side dedupe by message_id = exactly-once display.**

**Key principle:** the push path is an **optimization**; the **sync-from-cursor** path is the source of truth. Pushes can be lost; sync catches up.

## 6. Deep dive: ordering

- Global ordering is unnecessary. **Per-conversation ordering** matters.
- Assign a **monotonic sequence number per conversation**:
    - Option A: the conversation's **owning chat server** (conversations partitioned by `conversation_id` via consistent hashing) assigns sequence numbers in memory (single writer), persisted with the message.
    - Option B: atomic increment per conversation in Redis or the DB (`INCR conv:{id}:seq`).
    - Option C: Snowflake IDs (time-ordered, but concurrent senders across servers may interleave slightly; acceptable for many apps).
- Clients sort by the sequence number and detect **gaps** (missing seq means fetch it).
- Two users sending "simultaneously" get **a** consistent order that everyone sees identically.

## 7. Deep dive: storage

**Access pattern:** "get the latest N messages of conversation X; page backward." Write-heavy, append-only.

```
messages
  PRIMARY KEY ((conversation_id, bucket), message_seq) CLUSTERING ORDER BY (message_seq DESC)
  sender_id, body / media_ref, created_at, client_msg_id
```

- **Cassandra/ScyllaDB/HBase** (Discord moved from Cassandra to ScyllaDB; Facebook Messenger used HBase, later MyRocks).
- **Bucket** by time (e.g., monthly) or message count so huge channels don't create unbounded partitions (Discord's lesson).
- **Inbox/conversation list per user:** `user_conversations(user_id, last_activity_ts, conversation_id, unread_count, last_message_preview)`.

**Unread counts:** per (user, conversation) counter, updated on deliver/read. Eventually consistent is fine.

**End-to-end encryption (WhatsApp):** the server stores ciphertext only (Signal protocol), may delete messages after delivery, and history lives on devices. That changes the storage design (store-and-forward instead of a permanent history).

## 8. Deep dive: group chat fan-out

- Small groups (≤ ~500): **fan-out on write**. For each member, route to their gateways; offline members get push notifications.
- Store the message **once** per conversation (not per member). Members read from the conversation's partition, and each tracks a read cursor.
- Large channels (Slack/Discord with 100K+ members): don't push to everyone. Push to **online, currently viewing** members; others get a badge/unread marker and fetch on open. Discord routes guild events through a per-guild process (Elixir/Erlang actor) that fans out to connected sessions.

## 9. Presence

- Online status = has an active connection + recent heartbeat.
- Store in Redis with a TTL (`presence:{user} = online, EX 60`; heartbeats refresh it).
- **Fan-out of presence changes is expensive** (every friend gets notified when you go online or offline). Mitigations:
    - Only push presence to users **currently viewing** a chat with you (subscribe on view)
    - Debounce flapping (mobile networks)
    - Fetch presence lazily when the chat list is opened
- "Last seen" can be eventually consistent.

## 10. Typing indicators, read receipts

- Typing: ephemeral, fire-and-forget over WS, not persisted, rate limited (once per 3s).
- Read receipts: persisted as a per-user read cursor (`last_read_seq` per conversation). Send "read up to seq N" rather than per-message receipts.

## 11. Multi-device

- Each device has its own session and sync cursor.
- Messages sent from one device are delivered to the sender's other devices too.
- Device-specific keys for E2E (WhatsApp multi-device: each message encrypted per device).

## 12. Failure modes

| Failure | Mitigation |
|---|---|
| Gateway crash | Clients reconnect (jittered) to another gateway; sync from cursor fills gaps |
| Gateway deploy | Drain gradually; tell clients to reconnect elsewhere; avoid a reconnect storm |
| Message store slow | Ack only after durable write (correctness), backpressure on senders |
| Session store stale (wrong gateway) | Delivery fails → treat as offline → push notification + sync |
| Duplicate sends from retries | Dedupe by (sender, client_msg_id) |
| Network partition between DCs | Users homed to a region; conversations homed to a region (cross-region chats route to the home region) |

## 13. Follow-ups

- **Media:** upload to blob storage via a pre-signed URL; the message carries a media reference plus thumbnail; CDN delivery; E2E-encrypted media with keys in the message.
- **Search:** server-side index (if not E2E) via CDC to Elasticsearch; with E2E, search is on-device only.
- **Message edits/deletes:** new events with references to the original (soft delete); clients apply them.
- **Rate limiting & spam:** per-user send limits; ML spam detection asynchronously.
- **WhatsApp scale fact:** ~2M connections per server with Erlang/FreeBSD tuning (2012), with a small engineering team.
