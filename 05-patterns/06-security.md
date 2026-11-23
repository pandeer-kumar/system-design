# Security for System Design

You don't need to be a security engineer, but a senior design mentions these where relevant.

## Authentication (who are you?)

- **Sessions:** server-side session store (Redis) + an `HttpOnly`, `Secure`, `SameSite` cookie. Easy revocation.
- **JWT (stateless tokens):** signed claims; no lookup needed. **Hard to revoke.** Use short expiry (5–15 min) + refresh tokens + a denylist for emergencies.
- **OAuth 2.0 / OIDC:** delegated authorization / federated login. Authorization Code + **PKCE** for mobile and SPAs.
- **API keys:** for server-to-server/developer APIs. Hash them at rest, scope them, and support rotation.
- **mTLS:** service-to-service identity (service mesh, SPIFFE/SPIRE).
- **MFA, WebAuthn/passkeys** for users.

## Authorization (what can you do?)

- **RBAC** (roles), **ABAC** (attributes/policies), **ReBAC** (relationship-based: "can view if member of the folder's team").
- **Google Zanzibar** (ReBAC at scale; open-source descendants SpiceDB, OpenFGA): tuples like `doc:42#viewer@user:alice`, consistent checks using "zookies" (snapshot tokens to avoid the new-enemy problem).
- Enforce authorization **in every service** (don't trust the gateway alone); check object-level authorization (IDOR is the #1 API vulnerability in the OWASP API Top 10).

## Data protection

- **In transit:** TLS everywhere (including internal).
- **At rest:** disk/DB encryption (KMS-managed keys); **envelope encryption** (data key encrypted by a master key).
- **Field-level encryption / tokenization** for PII and card data (PCI scope reduction: store tokens, keep the card vault separate).
- **Secrets management:** Vault, AWS Secrets Manager. Never in code or env files in repos; rotate regularly.
- **Data minimization and retention policies;** crypto-shredding for deletion.

## Common attacks and defences

| Attack | Defence |
|---|---|
| DDoS (L3/4/7) | CDN/anycast absorption, WAF, rate limiting, autoscaling, SYN cookies |
| Credential stuffing / brute force | Rate limits per account and IP, CAPTCHA, MFA, breached-password checks |
| SQL injection | Parameterized queries, ORM |
| XSS | Output encoding, CSP |
| CSRF | SameSite cookies, CSRF tokens |
| SSRF | Allowlist outbound destinations; block metadata IPs (169.254.169.254) |
| Replay attacks (webhooks/APIs) | Timestamps + nonces + signatures (HMAC) |
| IDOR | Object-level authz checks; non-guessable IDs (defence in depth, not a substitute) |
| Enumeration (users, IDs) | Uniform responses, random IDs, rate limits |

## Multi-tenancy isolation

- Tenant ID on every row and query (row-level security in Postgres), or schema/DB per tenant for strong isolation.
- Noisy-neighbour protection: per-tenant rate limits and quotas, shuffle sharding, cells.

## Audit and compliance

- Immutable audit logs (who did what, when): append-only, ideally write-once storage.
- Compliance regimes: GDPR (consent, deletion, residency), PCI-DSS (cards), HIPAA (health), SOC 2.

## Interview sound bite

> "Card numbers never touch our main services. The client tokenizes them directly with the payment vault, so we only store tokens, which keeps most of the system out of PCI scope. Service-to-service calls use mTLS through the mesh, and authorization is checked per object in each service, not only at the gateway."
