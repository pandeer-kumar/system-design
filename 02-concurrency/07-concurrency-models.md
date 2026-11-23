# Concurrency Models: Threads, Event Loops, Actors, Async

How a server handles many concurrent requests determines its scalability profile.

## 1. Thread-per-request (blocking I/O)

```
Request → dedicated thread → blocking DB call → blocking HTTP call → response
```
- Examples: classic Java Servlet/Tomcat, Spring MVC, Rails/Puma, Django (with workers).
- ✅ Simple mental model, easy debugging, stack traces make sense.
- ❌ Each thread ~1 MB stack plus context switch costs. Ceiling of roughly a few thousand concurrent requests.
- ❌ A slow downstream exhausts the thread pool, and the whole service stalls (**cascading failure**). Mitigate with bulkheads and timeouts.

## 2. Event loop / reactor (non-blocking I/O)

```
Single thread: loop { events = epoll_wait(); for e in events: run callback(e) }
```
- Examples: Node.js, Nginx, Redis, Netty, Envoy, Python asyncio, Vert.x.
- Uses OS readiness APIs: **epoll** (Linux), kqueue (BSD/macOS), IOCP (Windows), **io_uring** (Linux, completion-based).
- ✅ Handles 10K–1M+ connections with few threads (the C10K/C10M problem).
- ❌ **Any blocking or CPU-heavy call blocks everyone.** One slow JSON parse stalls the whole loop.
- ❌ Callback hell or "function coloring" (async/await everywhere).
- **Scale across cores:** one loop per core (Nginx workers, Node cluster, Netty event loop groups). Redis 6+ uses I/O threads with a single execution thread.

**Why Redis is single-threaded and fast:** in-memory operations are ~µs, so the bottleneck is network I/O, not CPU. Single-threading means **every command is atomic** with no locks. That's why Lua scripts and `INCR` are race-free.

## 3. Virtual threads / green threads / goroutines (M:N scheduling)

- Examples: **Go goroutines**, **Java 21 virtual threads (Project Loom)**, Erlang processes, Kotlin coroutines.
- The runtime multiplexes millions of lightweight threads onto N OS threads. Blocking calls park the lightweight thread, not the OS thread.
- ✅ Blocking-style code with event-loop scalability.
- ❌ Pinning issues (Java: `synchronized` blocks pinned carriers before JDK 24), still need care with CPU-bound work, and **you can now overload downstreams far more easily**. A million concurrent requests is a lot of DB connections. Use semaphores.

## 4. Actor model

- **Actors** are independent entities with private state and a mailbox. They communicate only via **async messages**, and process one message at a time.
- Examples: **Erlang/OTP**, Akka (JVM), Orleans (.NET, "virtual actors"), and Cloudflare Durable Objects (actors at the edge).
- ✅ **No shared state, so no locks.** Each actor is a single writer for its state.
- ✅ Location-transparent: actors can be on other machines, which maps naturally to distribution.
- ✅ Supervision trees (Erlang): "let it crash" and supervisors restart failed actors.
- ❌ Mailbox overflow (needs backpressure), ordering only per sender-receiver pair, harder to reason about global invariants.

**System design relevance:** the actor model is how you remove contention at scale. "One actor per chat room / game session / shopping cart / seat map" is the same as "one Kafka partition per key, single consumer." WhatsApp's Erlang backend ran each connection as a process.

## 5. CSP (Communicating Sequential Processes)

- Goroutines plus **channels** (Go), Clojure core.async.
- Unlike actors, channels are first-class and anonymous. Processes don't have addresses.
- Bounded channels give natural backpressure.

## 6. Reactive streams

- RxJava, Project Reactor (Spring WebFlux), Akka Streams.
- Async streams with **demand-based backpressure** (subscriber requests N items).
- Powerful but complex. Virtual threads are reducing the need for them in Java.

## 7. Data parallelism / MapReduce

- Split data, process partitions in parallel, combine. Spark, Flink, MapReduce.
- Embarrassingly parallel. Coordination only at shuffle/reduce.

## 8. Single-threaded deterministic processing (the LMAX pattern)

- **One thread processes every event for a domain in sequence**, entirely in memory, with input events journaled to disk/replicas first.
- LMAX Exchange: **6M orders/sec on one thread** using the Disruptor (a lock-free ring buffer).
- No locks, deterministic, and replayable. Recovery = replay the journal. Replicas run the same input and get the same state (state machine replication).
- **Used by stock exchanges, matching engines, and some payment ledgers.** See [06-case-studies/17-stock-exchange.md](../06-case-studies/17-stock-exchange.md).

## Choosing a model

| Workload | Good fit |
|---|---|
| CRUD API, moderate scale | Thread-per-request (or virtual threads) |
| Huge numbers of idle connections (chat, push, IoT) | Event loop or goroutines/Erlang |
| Proxies, gateways | Event loop (Nginx, Envoy) |
| Stateful entities with high write contention (game rooms, carts, docs) | Actors / single writer per entity |
| Ultra-low-latency, ordered processing | Single-threaded event processor + journal |
| Batch analytics | Data parallel (Spark) |
| Streaming | Partitioned stream processing (Flink, Kafka Streams): single-threaded per partition |

## The unifying principle: single writer per partition

Look at Kafka consumers, Flink operators, actors, Redis, LMAX, and DynamoDB partitions: **the scalable pattern is to partition state so each partition has exactly one writer, and process each partition's events sequentially.** Parallelism comes from many partitions, and correctness from sequential processing inside each one.

> Interview sound bite: "Rather than locks, I'll partition by game_id so all events for a game go to one partition and one consumer processes them sequentially. Concurrency becomes ordering, and we scale by adding partitions."
