# Famous Outages and What They Teach

Citing real incidents in an interview ("this is how the 2017 S3 outage happened") is a strong signal of experience. Each entry has the pattern and the lesson.

> Details are simplified from public postmortems. Read the originals for depth.

---

### AWS S3 us-east-1 (Feb 2017): fat-finger at scale

- **What:** an engineer ran a playbook command to remove a few servers from a billing subsystem; a typo removed far more capacity, including S3's index and placement subsystems. They needed a full restart, which took hours at that scale. Many sites (and the AWS status dashboard itself, which depended on S3) went down.
- **Lessons:** tooling should limit blast radius (rate-limit capacity removal, enforce minimum capacity); regularly test restart and recovery at full scale; **don't host your status page on the thing it monitors**; region-level dependency concentration.

### AWS us-east-1 Kinesis (Nov 2020): thread limits

- **What:** adding capacity to the Kinesis front-end fleet raised the number of threads each server needed (every server kept threads for every other server), exceeding OS thread limits. Front ends failed; many AWS services that depended on Kinesis (Cognito, CloudWatch) degraded.
- **Lessons:** O(N²) connection/thread patterns break at scale; hidden dependencies between services; cell-based architectures to bound fleet size.

### AWS us-east-1 DynamoDB DNS (Oct 2025): automation race condition

- **What:** a race between components of DynamoDB's automated DNS management system left an empty DNS record for the regional endpoint. Everything that depended on DynamoDB in us-east-1, including other AWS services, failed for hours, with long recovery tails (EC2 instance launches backed up).
- **Lessons:** races in control-plane automation; foundational services have huge blast radii; recovery and backlog drain often take longer than the fix.

### Facebook global outage (Oct 2021): BGP withdrawal

- **What:** a maintenance command accidentally disconnected Facebook's backbone. DNS servers, designed to withdraw BGP routes when they couldn't reach data centers, did exactly that, making facebook.com, WhatsApp, and Instagram unresolvable. Internal tools (and badge access) also depended on the same network, which slowed recovery.
- **Lessons:** safety mechanisms can amplify failures; out-of-band access for recovery; avoid circular dependencies between recovery tools and the production system.

### Cloudflare (July 2019): regex CPU exhaustion

- **What:** a new WAF rule with a regex causing catastrophic backtracking was deployed globally at once, pinning CPU on every edge server worldwide.
- **Lessons:** **staged rollouts for config too**, not just code; use linear-time regex engines (RE2); per-change kill switches.

### Cloudflare (Nov 2025): bad config file

- **What:** a database permissions change caused a generated feature file for bot management to double in size. It exceeded a hard-coded limit in the proxy, which panicked on load, failing traffic across Cloudflare's network. The file was regenerated periodically, so the system flapped between good and bad before stabilizing.
- **Lessons:** validate generated config like code; fail safe (keep the last good config) on invalid input instead of crashing; global propagation of data files is a deployment.

### CrowdStrike (July 2024): global kernel-level update

- **What:** a faulty content/config update to the Falcon sensor (kernel driver) was pushed to millions of Windows hosts simultaneously, causing boot loops (BSOD). Airlines, hospitals, and banks were down; recovery required manual intervention per machine.
- **Lessons:** **staged rollouts and canaries for every change, including "content"**; validate inputs in privileged code; plan for recovery when remote fixes are impossible.

### Google Cloud (June 2025): null pointer in a global policy system

- **What:** a new quota-policy feature without a feature flag hit a null-pointer crash loop when a policy with blank fields replicated globally within seconds. Service Control crashed in every region, failing API requests across many Google Cloud services. Restarts then created a herd on the backing database in a large region.
- **Lessons:** feature-flag new code paths; globally replicated config/data is a single point of failure; exponential backoff on restart.

### GitHub (Oct 2018): network partition + MySQL failover

- **What:** a 43-second network partition between the US East Coast data center and the hub triggered an automated MySQL failover (Orchestrator) to the West Coast. Writes were then accepted in both locations; reconciling the divergent data and replication took 24+ hours of degraded service.
- **Lessons:** automated cross-region failover can be worse than a brief outage; **split-brain and divergent writes are very expensive to fix**; consider failover policies that require quorum/human approval across regions; know your RPO.

### GitHub (2012): failover + Redis ID reuse

- **What:** a MySQL failover lost some auto-increment IDs that had been used as keys in Redis; new rows reused the IDs, so some users briefly saw others' private data.
- **Lesson:** async replication loses writes on failover, and **IDs generated before the loss may already be referenced elsewhere**.

### Knight Capital (Aug 2012): $440M in 45 minutes

- **What:** a deployment missed one of eight servers; an old, repurposed feature flag activated dead code on that server, which sent millions of erroneous orders.
- **Lessons:** deployment verification; never repurpose flags; kill switches; automated anomaly detection in trading.

### Slack (Jan 2021): post-holiday traffic + autoscaling and network limits

- **What:** Monday after the holidays, everyone's clients reconnected at once. Cloud network infrastructure (AWS Transit Gateways) couldn't scale fast enough, packet loss rose, and the autoscaling and monitoring systems were themselves affected.
- **Lessons:** predictable traffic peaks need pre-scaling; reconnect storms; dependencies on provider infrastructure limits.

### Discord (2020, and the Cassandra → ScyllaDB migration)

- **What:** hot partitions (very active channels), GC pauses, and compaction backlogs in Cassandra caused latency spikes; they migrated messages to ScyllaDB with a Rust data service in front that **coalesces identical requests** (request coalescing) and does consistent-hash routing.
- **Lessons:** hot partitions; request coalescing; bounded partition sizes (buckets).

### Roblox (Oct 2021): 73-hour outage

- **What:** a Consul cluster (service discovery and config) degraded due to a new streaming feature under high load + a BoltDB freelist performance pathology. Everything depended on Consul, so the whole platform was down. Cold-starting with caches empty created more load.
- **Lessons:** the control plane is critical (watch its dependencies); feature changes to core infra need careful rollout; plan cold start and warm-up; avoid single shared coordination clusters for everything.

### Atlassian (April 2022): deletion script

- **What:** a script meant to delete a legacy app's data was given site IDs instead of app IDs, deleting ~400 customer sites; restoration took up to two weeks.
- **Lessons:** destructive operations need soft deletes, staged execution, and validation of inputs; **restoring individual tenants** from backups must be practiced.

### GitLab (Jan 2017): database deletion

- **What:** during a replication incident, an engineer ran `rm -rf` on the primary's data directory instead of the replica's. 5 backup mechanisms were found to be non-functional; 6 hours of data were lost.
- **Lessons:** **untested backups are not backups**; distinct prompts/hostnames for prod; guardrails on destructive commands.

---

## Patterns across outages

| Pattern | Defences |
|---|---|
| **Changes cause most outages** (code, config, data) | Staged rollouts, canaries, bake times, automatic rollback, feature flags |
| **Global, instant propagation** | Treat config/data pushes like deployments; cells; regional isolation |
| **Hidden or circular dependencies** | Dependency mapping; static stability; out-of-band recovery tools |
| **Automation amplifying failures** | Rate-limit automation; human-in-the-loop for big blast-radius actions; safety checks |
| **Retry/reconnect storms and cold starts** | Jittered backoff, retry budgets, load shedding, warm-up |
| **Split brain after failover** | Fencing, quorum-based decisions, careful cross-region failover policy |
| **Untested recovery paths** | Game days, restore drills, chaos engineering |
| **Resource limits nobody tracked** | Capacity tests at scale; limits as monitored metrics |

**Interview usage:** "One risk with automatic cross-region DB failover is what happened at GitHub in 2018: a short partition led to writes in both regions and a day of reconciliation. So I'd make regional failover of the primary a human decision and automate only the stateless tier."
