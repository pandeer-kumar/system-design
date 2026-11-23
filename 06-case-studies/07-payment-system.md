# Case Study 07: Payment System (Stripe / PayPal / internal payments platform)

> Tests: idempotency, exactly-once effects across unreliable external systems, double-entry ledgers, reconciliation, and the consistency of money.

## 1. Requirements

**Functional**
- Accept payments from customers (card, wallet) for orders
- Payouts to merchants/sellers
- Refunds, partial refunds
- Payment status queries; webhooks to merchants
- Ledger of all money movement (audit)

**Non-functional**
- **Correctness above all:** never double-charge, never lose a payment, balances always reconcile
- Durability: zero data loss for committed transactions
- Availability: 99.99% for payment acceptance (but **correctness > availability**)
- Latency: seconds acceptable (external PSPs take 1–3s)
- Compliance: PCI DSS, audit trails
- Scale: ~1K–10K TPS peak (payments are lower volume than you'd think, but every one matters)

## 2. Key entities

```
payment_intents(id, merchant_id, customer_id, amount, currency, status, idempotency_key, created_at, version)
  status: CREATED → PROCESSING → SUCCEEDED | FAILED | REQUIRES_ACTION | CANCELED
payment_attempts(id, intent_id, psp, psp_reference, status, request_payload, response_payload)
ledger_entries(id, transaction_id, account_id, direction DEBIT/CREDIT, amount, currency, created_at)   -- append-only
accounts(id, type: customer_receivable | merchant_payable | platform_fees | psp_clearing | ..., currency)
idempotency_keys(key, merchant_id, request_hash, response, status, locked_at)
outbox(id, topic, payload, ...)
```

## 3. High-level design

```
Merchant/Client → API Gateway (auth, rate limit)
   → Payment Service (orchestrator, state machine)
        ├── Idempotency layer (DB)
        ├── Risk/Fraud Service (sync scoring, ~100ms)
        ├── Card Vault / Tokenization (PCI zone)
        ├── PSP Adapter(s) → Stripe/Adyen/card networks (external)
        ├── Ledger Service (double-entry, append-only)
        └── Outbox → Kafka → Webhook Service, Notifications, Analytics, Payout scheduler
   Reconciliation Service (daily/hourly: compare ledger vs PSP settlement files vs bank statements)
```

## 4. Deep dive: idempotency end to end

**Client → us:** `Idempotency-Key` header (merchant-scoped). Stored with the request hash and final response. See [02-concurrency/06-idempotency.md](../02-concurrency/06-idempotency.md).

**Us → PSP:** pass **our own idempotency key** (e.g., `payment_attempt_id`) to the PSP. If we time out and retry, the PSP dedupes. **This is the critical part.** Without it, a timeout and retry means a double charge.

**Unknown outcome handling (the hardest case):**
```
We call PSP: charge($50, idem=attempt_123) → TIMEOUT
Did it charge? Unknown.
```
- **Never** mark it FAILED and let the user retry with a new attempt (that's a double charge).
- Mark the attempt `UNKNOWN`/`PENDING`. **Retry with the same idempotency key** (safe), or **query the PSP** for the status of `attempt_123`.
- A background **resolver** polls the PSP for unknown attempts; PSP webhooks also report the final status.
- Reconciliation with settlement files is the last line of defence.

## 5. Deep dive: state machine with concurrency control

Payment status transitions must be **atomic and monotonic**:
```sql
UPDATE payment_intents
SET status='SUCCEEDED', version=version+1
WHERE id=:id AND status='PROCESSING';    -- conditional transition
```
- Webhooks and synchronous responses can race (the PSP webhook arrives before our sync response handler runs). Conditional transitions make both paths idempotent; whichever arrives first wins, and the other is a no-op.
- Never allow `SUCCEEDED → FAILED`. Encode valid transitions.

## 6. Deep dive: double-entry ledger

Every money movement is a **transaction** with ≥2 entries whose **debits = credits**.

Customer pays $100, platform fee $3:
```
txn_1:
  DEBIT  psp_clearing          100.00
  CREDIT merchant_payable       97.00
  CREDIT platform_fee_revenue    3.00
```
Refund of $100:
```
txn_2:
  DEBIT  merchant_payable       97.00
  DEBIT  platform_fee_revenue    3.00   (or the fee is not refunded: policy)
  CREDIT psp_clearing          100.00
```

**Principles:**
- **Immutable, append-only.** Never update or delete entries; corrections are new reversing entries.
- **Balances are derived** (sum of entries), optionally cached in a balance table updated **in the same transaction** as the entries.
- **Invariant check:** for every transaction, `sum(debits) == sum(credits)`. Enforce it in code + DB constraint/trigger + continuous audit.
- Use **integer minor units** (cents) or decimals. **Never floats.**
- Multi-currency: entries are per currency; FX conversion is an explicit transaction through FX accounts.

**Concurrency on balances:**
- Hot accounts (the platform fee account, which gets every transaction) are a contention point if you update a balance row on every write. Fixes: don't maintain a running balance for hot accounts (compute by aggregation), **shard the account** into sub-accounts, or batch updates.
- Overdraft prevention for wallet balances: `UPDATE balances SET amount = amount - :x WHERE account=? AND amount >= :x` inside the same transaction as the ledger entries, or serializable isolation.

**Storage:** a strongly consistent relational DB (Postgres/MySQL, or Spanner/CockroachDB for scale). Partition by account ID; cross-account transactions on different shards need distributed transactions, so **co-locate** or use a DB with native distributed transactions. Some companies use dedicated ledger DBs (TigerBeetle, Square's Books, Stripe's internal ledger).

## 7. Deep dive: the DB-write + PSP-call atomicity problem

You can't put an external API call inside a DB transaction. Pattern:

```
1. TXN: create payment_attempt(status=PENDING, idem_key) — commit
2. Call PSP with idem_key (outside any transaction)
3. TXN: update attempt + intent status, write ledger entries, write outbox event — commit
4. If crash between 2 and 3: resolver finds PENDING attempts older than N seconds → query PSP → complete step 3
```
That's a mini-saga with **recovery points**. Stripe's idempotency key design records which step was last completed so retries resume from there.

## 8. Deep dive: reconciliation

The external world is the truth for money movement. Daily (or more frequently):
- Download PSP **settlement reports** and bank statements.
- Match each external record to internal ledger entries (by PSP reference).
- Classify mismatches: missing internally (we lost a success → fix), missing externally (we think success, PSP says no → investigate), amount mismatch.
- Auto-resolve the common cases; queue the rest for finance ops.
- **Reconciliation is what makes the system trustworthy.** Bugs will happen; reconciliation catches them.

## 9. Webhooks to merchants

- Events from the outbox → Webhook Service → merchant endpoint.
- **At-least-once** with exponential backoff for up to ~3 days; signed (HMAC + timestamp).
- Merchants dedupe by event ID; include an event sequence number or a "fetch latest object" pattern, because webhooks arrive out of order.

## 10. Payouts

- A scheduler aggregates `merchant_payable` balances → creates payout transactions → bank transfer via ACH/SEPA files or APIs.
- Same idempotency + state machine + reconciliation discipline.
- Holds/reserves for risk (a rolling reserve of X% for N days).

## 11. Failure modes

| Failure | Handling |
|---|---|
| PSP timeout | Retry with the same idempotency key; resolver; never create a new attempt blindly |
| PSP down | Route to a secondary PSP (smart routing) **only if the first attempt definitively failed** |
| Duplicate client request | Idempotency key replay |
| Webhook and sync response race | Conditional state transitions |
| Ledger imbalance bug | Invariant checks, alerts, reconciliation; ledger is append-only so fixes are reversing entries |
| DB failover | Synchronous replication (RPO=0) for the ledger; no async-replica promotion that could lose committed payments |
| Region outage | Payments homed per merchant/region; other regions keep working; failover with sync-replicated DB (Spanner-like) or accept unavailability over inconsistency |

## 12. Follow-ups

- **Fraud:** sync risk scoring (rules + ML) before authorization; 3DS challenges (REQUIRES_ACTION); async post-transaction monitoring.
- **Auth vs capture:** authorize at checkout (reserve funds), capture at shipment. Uncaptured authorizations expire after ~7 days.
- **Currency precision:** JPY has 0 decimals, BHD has 3. Store amount + currency exponent.
- **Exactly-once to the ledger from Kafka:** consumers write ledger entries with a unique `(source_event_id)` constraint. Duplicates fail the insert, so the operation is idempotent.
- **Why not eventual consistency for balances?** Overdrafts and double spends. Wallet debits need linearizable checks.
