# Technology Deep Dives

FAANG interviewers rarely accept "we'll use Kafka" or "put it in Redis." They ask how the technology works inside, what it guarantees, and how it fails. Each chapter goes one to three levels below the API and ends with interview questions and answers.

| # | Chapter | Read it before |
|---|---|---|
| 01 | [Kafka Internals](01-kafka.md) | Any event-driven design; message queue, ad click, metrics case studies |
| 02 | [Redis Internals](02-redis.md) | Caching, rate limiting, leaderboards, locks, sessions |
| 03 | [Task Queues: RabbitMQ, SQS, Celery, Sidekiq, DB-backed queues](03-task-queues.md) | Background jobs, notifications, job scheduler, task queue case study |
| 04 | [PostgreSQL and MySQL Internals](04-postgresql-mysql.md) | Any design with a relational system of record (payments, booking) |
| 05 | [Cassandra and DynamoDB](05-cassandra-dynamodb.md) | Chat, feeds, time series, KV store case study |
| 06 | [Elasticsearch / OpenSearch Internals](06-elasticsearch.md) | Search, log analytics, typeahead |
| 07 | [ZooKeeper and etcd](07-zookeeper-etcd.md) | Leader election, locks, service discovery, shard metadata |
| 08 | [Stream Processing (Flink)](08-stream-processing-flink.md) | Ad click aggregation, top-K, metrics, real-time analytics |

How to use this section: for each technology, practise explaining the three levels from the [deep-dive playbook](../00-interview-framework/04-deep-dive-playbook.md) out loud: what it is, how it works, and how it fails.

[← Back to the guide](../README.md)
