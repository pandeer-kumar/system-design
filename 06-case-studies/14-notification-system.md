# Case Study 14: Notification System (push, SMS, email, in-app)

> Tests: fan-out, reliability with flaky third parties, dedup/idempotency, priorities, rate limiting, user preferences, and scheduling.

## 1. Requirements

**Functional**
- Send notifications via push (APNs/FCM), SMS (Twilio), email (SES/SendGrid), and in-app
- Triggered by events (order shipped) or campaigns (marketing blast to 50M users)
- User preferences (opt-outs per channel/category), quiet hours, time zones
- Templates and localization
- Delivery tracking (sent, delivered, opened)

**Non-functional**
- Scale: 1B+ notifications/day; campaigns of 100M in a short window
- Transactional notifications (OTP, security alerts) delivered within seconds; marketing can be delayed
- **No duplicates** (two identical push notifications are annoying; two OTPs are confusing)
- At-least-once for critical notifications
- Isolation: a slow email provider must not delay OTP SMS

## 2. High-level design

```
Producers (services) → Notification API (validate, idempotency key) → Kafka "notification_requests"
                                                                       ↓
                                                  Notification Processor:
                                                    - fetch user prefs, devices, locale
                                                    - apply opt-outs, quiet hours, frequency caps
                                                    - render template
                                                    - dedupe
                                                       ↓ per channel & priority
                         ┌──────────────┬──────────────┬──────────────┐
                   push-high queue  sms queue     email queue     in-app (write to inbox store + WS push)
                         ↓              ↓              ↓
                   Push workers    SMS workers    Email workers  → providers (APNs/FCM, Twilio, SES)
                         ↓ results / callbacks (delivery receipts, bounces, invalid tokens)
                   Status store + analytics; invalid device tokens cleaned up
Campaign Service: segment users → batch-enqueue (throttled) → same pipeline
Scheduler: delayed sends (time-zone aware) → enqueue at the right time
```

## 3. Deep dive: isolation and priorities

- **Separate queues per channel and per priority** (bulkheads). OTP/security queues get dedicated workers and capacity; marketing goes to low-priority queues that can lag for hours.
- Provider-specific rate limits (APNs, Twilio account throughput, SES sending rate) are enforced with token buckets per provider in the workers.
- **Circuit breakers per provider;** failover to a secondary provider for critical channels (SMS: Twilio → another aggregator).

## 4. Deep dive: dedup and idempotency

Sources of duplicates: producer retries, Kafka redelivery, worker crashes after sending but before acking, and campaign re-runs.

- **Idempotency key** per notification: producers pass `(event_id, user_id, notification_type)` or an explicit key.
- Processor: `SET dedup:{key} 1 NX EX 86400` in Redis (or a unique insert in the DB). If it already exists, skip.
- **The send itself:** a worker crashes after the provider accepted the message → redelivery → duplicate send. Mitigate by recording "sending" state before calling the provider and "sent" after. On redelivery with state "sending," check the provider status API if one exists, or accept a rare duplicate (most providers have no idempotency key). **State this trade-off honestly:** exactly-once to APNs/SMS isn't fully achievable; we minimize duplicates.
- Collapse keys (APNs `apns-collapse-id`, FCM `collapse_key`) let the device show only the latest of a series of notifications.

## 5. Deep dive: campaign fan-out (100M users)

- Segment query (e.g., from the data warehouse) → a list of user IDs, exported in chunks.
- **Throttled enqueue:** spread over a window to respect provider limits and avoid self-DDoS (e.g., app servers stampeded when 100M users tap the push at once).
- Per-user **frequency caps** (max N marketing pushes/day), checked atomically in Redis (`INCR` with TTL).
- Time zone aware: bucket users by local send time and schedule each bucket.

## 6. User preferences and device tokens

```
preferences(user_id, channel, category, enabled, quiet_hours, timezone)
devices(user_id, device_id, platform, push_token, app_version, last_seen)
```
- Heavily cached (read on every notification).
- Invalid token feedback from APNs/FCM → delete the token (otherwise you waste sends, and providers penalize senders).

## 7. In-app notifications (inbox)

- Store per user: `(user_id, notification_id DESC) → payload, read flag` in Cassandra/DynamoDB.
- Unread count: counter per user (eventually consistent), or computed with a cap ("99+").
- Real-time: push over the WebSocket if online (see the chat case study).

## 8. Reliability

- Kafka with replication; consumers commit offsets after the handoff to the provider.
- Retries with exponential backoff for transient errors; DLQ for permanent failures.
- **Critical notifications:** at-least-once with a fallback channel (push fails → SMS).
- Monitoring: send success rate per provider, queue lag per priority, latency from event to delivery.

## 9. Failure modes

| Failure | Handling |
|---|---|
| Email provider outage | Circuit breaker; queue builds (marketing can wait); fail over for transactional email |
| Campaign floods the pipeline | Low-priority queues + separate workers; OTP unaffected |
| Duplicate events from producers | Idempotency key dedup |
| User opted out mid-campaign | Preferences checked at send time, not only at enqueue time |
| Stale device token | Provider feedback → cleanup |

## 10. Follow-ups

- **Digesting/batching:** "5 people liked your post" instead of 5 pushes. Delay low-priority notifications into a short window and aggregate (a stateful stream window per user).
- **Analytics:** open/click tracking via redirect links and pixels; delivery receipts.
- **Ordering:** usually doesn't matter, except for status sequences (order shipped → delivered); use a version per entity and collapse keys.
