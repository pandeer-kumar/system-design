# Networking for System Design

## The OSI layers that matter

| Layer | Examples | Why it matters |
|---|---|---|
| L7 Application | HTTP, gRPC, WebSocket, DNS | Routing by path/header, auth, retries |
| L4 Transport | TCP, UDP, QUIC | Connections, ordering, reliability |
| L3 Network | IP | Routing, anycast |

L4 load balancers route by IP and port (fast, opaque). L7 load balancers understand HTTP (smart routing, more CPU).

## TCP

- **Connection-oriented**, reliable, ordered byte stream.
- **3-way handshake** (SYN, SYN-ACK, ACK) = 1 RTT before data. Add TLS 1.3 = +1 RTT (0-RTT on resumption). TLS 1.2 = +2 RTT.
- **Flow control** (receiver window) and **congestion control** (slow start, AIMD, CUBIC, BBR).
- **Head-of-line blocking:** one lost packet stalls every byte behind it.
- **TIME_WAIT:** closed connections linger 2×MSL (~60s). High connection churn can exhaust ephemeral ports. **This is why connection pooling and keep-alive matter.**
- **Nagle's algorithm** batches small writes and adds latency. Disable it (`TCP_NODELAY`) for latency-sensitive protocols.

## UDP

- No connection, no ordering, no reliability. Low overhead.
- Used for DNS, video/voice (WebRTC), gaming, QUIC, and metrics (StatsD).
- Use when late data is worthless (live video frame) or you build your own reliability.

## HTTP versions

| | HTTP/1.1 | HTTP/2 | HTTP/3 |
|---|---|---|---|
| Transport | TCP | TCP | QUIC (UDP) |
| Multiplexing | No (one request at a time per connection; browsers open ~6) | Yes, streams over one connection | Yes |
| Head-of-line blocking | App + TCP level | TCP level only | None (per-stream) |
| Header compression | No | HPACK | QPACK |
| Handshake | TCP + TLS | TCP + TLS | Combined, 1-RTT / 0-RTT |
| Connection migration | No | No | Yes (connection ID survives IP change, good for mobile) |

## Real-time communication options

| Technique | How | Pros | Cons | Use for |
|---|---|---|---|---|
| Short polling | Client asks every N sec | Simple | Wasteful, latency up to N | Rare updates, simple dashboards |
| Long polling | Server holds the request until data or timeout | Works everywhere | Reconnect overhead, ordering subtleties | Fallback, simple notifications |
| SSE (Server-Sent Events) | One-way server→client stream over HTTP | Simple, auto-reconnect, works with HTTP/2 | Server→client only, text only | Live feeds, notifications, LLM token streaming |
| WebSocket | Full-duplex over upgraded HTTP connection | Bi-directional, low overhead | Stateful connections, harder LB, needs a heartbeat | Chat, games, collaboration |
| WebRTC | Peer-to-peer UDP | Lowest latency, P2P | Complex (STUN/TURN/ICE) | Voice/video calls |

### Running WebSockets at scale (common deep dive)
- Connections are **stateful**: you need a mapping of user → gateway server (in Redis or a presence service).
- Load balancing: L4 or L7 with sticky connections. **Rebalancing is hard** because connections are long-lived.
- **Deploys drain connections.** Clients must reconnect with jitter, or you get a thundering herd.
- **Heartbeats** (ping/pong) detect dead connections. Mobile NATs drop idle connections after ~30s–5min.
- Memory per connection: ~10–50 KB including buffers → 1M connections ≈ 10–50 GB.
- File descriptor limits (`ulimit -n`) and kernel tuning matter.

## RPC: gRPC vs REST vs GraphQL

| | REST/JSON | gRPC | GraphQL |
|---|---|---|---|
| Encoding | JSON (text) | Protobuf (binary) | JSON |
| Transport | HTTP/1.1 or 2 | HTTP/2 | HTTP |
| Contract | OpenAPI (optional) | .proto (strict, codegen) | Schema |
| Streaming | No (SSE/WS separately) | Client, server, bidi streaming | Subscriptions |
| Browser | Native | Needs gRPC-Web proxy | Native |
| Best for | Public APIs, simplicity | Internal service-to-service, low latency | Client-driven aggregation, mobile/BFF |
| Gotchas | Over/under-fetching | LB must be L7-aware (HTTP/2 multiplexes all calls on one connection) | N+1 resolvers, caching is hard, query cost limits |

**Common trap:** gRPC behind an L4 load balancer. A single long-lived HTTP/2 connection pins all requests to one backend. Use L7 (Envoy) or client-side load balancing.

## DNS

- Hierarchical: root → TLD → authoritative. Results are cached by resolvers according to TTL.
- **Low TTL** (30–60s) = faster failover, more DNS load. **High TTL** = stale routing during failover.
- Many clients (JVMs historically, some mobile stacks) **ignore TTLs**. DNS failover is never instant.
- **GeoDNS / latency-based routing:** return the closest region's IP.
- **Anycast:** the same IP is announced from many locations; BGP routes to the nearest. Used by CDNs and DNS providers (Cloudflare, 1.1.1.1).

## Connection management (senior detail)

- **Connection pooling:** reuse TCP/TLS connections. A fresh TLS connection across regions costs 2–3 RTTs, which is 300ms+.
- **Pool sizing:** by Little's Law, pool size ≈ throughput × latency. Too small queues requests; too large overwhelms the DB. (Postgres: each connection is a process, so use PgBouncer.)
- **Keep-alive and idle timeouts:** mismatched timeouts between LB and backend cause intermittent 502s. The LB idle timeout should be shorter than the backend keep-alive.
- **Connection storms:** after an outage, every client reconnects at once. Use jittered backoff.

## Proxies

- **Forward proxy:** acts for clients (corporate egress, VPN)
- **Reverse proxy:** acts for servers (Nginx, Envoy, HAProxy). Handles TLS termination, compression, caching, routing, rate limiting.
- **API gateway:** a reverse proxy plus auth, rate limits, request transformation, and API key management.
- **Service mesh sidecar:** a proxy per service instance (Envoy in Istio/Linkerd) for mTLS, retries, and observability.
