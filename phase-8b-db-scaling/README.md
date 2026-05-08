# Phase 8b — Database Scaling

> **Concepts introduced:** Connection pooling (PgBouncer), read replicas, table partitioning, index strategy, slow query analysis, cache-aside refinement | **Builds on:** Phase 4 (PostgreSQL + Redis), Phase 8 (HPA, load testing)

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-8b-db-scaling/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **Connection pooling (PgBouncer)** | Multiplexes hundreds of app connections into a small pool of real DB connections | PostgreSQL forks a process per connection — 180 connections = 180 processes = high memory + CPU overhead |
| **Read replica** | Streaming replication from primary → standby; read-only queries routed to standby | Offloads SELECT traffic from the primary — reads scale horizontally, writes still go to one node |
| **Table partitioning** | Splits a large table into physical child tables by a key (date range) | The query planner reads only relevant partitions — a query on Q1 2026 never touches 2024 data |
| **Partial index** | Index covering only rows matching a WHERE condition | `status = 'pending'` is 0.75% of rows — a full index on status wastes space and slows writes |
| **Covering index** | Index that includes non-key columns (INCLUDE) | Satisfies a query entirely from the index — no heap fetch, dramatically lower I/O |
| **pg_stat_statements** | Extension tracking per-query execution stats across all calls | Identifies which queries consume the most total time — the right starting point before adding any index |
| **Cache-aside (refined)** | Per-resource cache keys, write-through invalidation, TTL by data freshness | Phase 4's single-key cache caused stampedes at scale — per-member keys isolate invalidation |

---

## The problem

> *CoverLine — 300,000 members. December. Open enrollment just ended.*
>
> Phase 8's HPA handled the traffic spike. Twenty backend pods served 40,000 concurrent users without breaking a sweat. The Kubernetes layer scaled beautifully.
>
> Then the post-mortem graphs arrived.
>
> During peak load the backend pods were healthy. P95 response time from the load balancer was 340ms — within SLA. But P95 at the *database* layer told a different story: **1,800ms**. The Prometheus graph showed a clear inflection point: as HPA scaled from 3 pods to 20, DB query latency climbed in lockstep.
>
> More pods → more concurrent connections → PostgreSQL spending more time scheduling and context-switching between connection processes → slower queries for everyone.
>
> `pg_stat_activity` at peak: **183 connections**, of which 61 were `idle in transaction` — holding locks while their client pods waited on upstream HTTP calls. The DB was at **97% CPU** with effective query throughput of 12 queries/second.
>
> The engineering team dug in:
>
> ```sql
> SELECT query, calls, mean_exec_time, total_exec_time
> FROM pg_stat_statements
> ORDER BY total_exec_time DESC LIMIT 5;
> ```
>
> | Query | Calls | Mean (ms) | Total (s) |
> |---|---|---|---|
> | `SELECT * FROM claims WHERE member_id = $1` | 2,847,000 | 38 | 108,000 |
> | `SELECT COUNT(*), SUM(amount) FROM claims` | 14,000 | 1,240 | 17,360 |
> | `SELECT * FROM claims WHERE status = 'pending'` | 890,000 | 180 | 160,200 |
> | `INSERT INTO claims ...` | 22,000 | 4 | 88 |
>
> Three patterns in 10 minutes of analysis:
>
> 1. **Connection exhaustion**: 183 connections at peak; PostgreSQL `max_connections = 200`. Two more HPA replicas would have saturated the DB entirely.
> 2. **No useful indexes**: `SELECT * FROM claims WHERE status = 'pending'` — full table scan, 8 million rows every time.
> 3. **One primary doing everything**: read-heavy dashboard queries competed with write transactions on the same node, the same disk, the same CPU.
>
> HPA solved the application tier. Now the database tier needs the same attention.

---

## Architecture

```
Before phase-8b:
  20 backend pods ──────────────────────────────► postgresql-0:5432
  (180 connections, DB CPU 97%, P95 query 1800ms)

After phase-8b:

  ┌─────────────────────────────────────────────────────────────────┐
  │  20 backend pods (write path)                                   │
  │  POST /claims → pgbouncer:5432 (pool) → postgresql-primary:5432 │
  └─────────────────────────────────────────────────────────────────┘
          │
          │ Redis cache-aside (per member_id, 5 min TTL)
          ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  20 backend pods (read path)                                    │
  │  GET /claims/<id> → Redis HIT (no DB) ── 80% of requests       │
  │                   → Redis MISS → pgbouncer-replica:5432         │
  │                                  └──► postgresql-replica:5432   │
  └─────────────────────────────────────────────────────────────────┘

  postgresql-primary ──streaming replication──► postgresql-replica
  (writes, WAL sender)                          (reads, hot standby)

  Connection counts:
    Before: 20 pods × 9 threads = 180 real PostgreSQL connections
    After:  PgBouncer pool = 20 real connections to primary
                           = 10 real connections to replica
            Backend pods connect to PgBouncer (up to 200 app connections)

  Query routing:
    INSERT / UPDATE / DELETE    → pgbouncer → postgresql-primary
    SELECT (member claims)      → Redis (cache hit, ~5ms)
    SELECT (cache miss)         → pgbouncer-replica → postgresql-replica
    SELECT (dashboard aggregate)→ Redis (60s TTL, ~5ms)
    SELECT (admin / reports)    → pgbouncer → postgresql-primary (direct)
```

---

## Scaling concepts: when to use each technique

| Technique | Solves | When to use | When NOT to use |
|---|---|---|---|
| **Connection pooler** | Too many DB connections | Always — first thing to add | Never skip this step |
| **Read replica** | Read-heavy workload, primary CPU saturation | Reads >> Writes (typical for most apps) | Replication lag is unacceptable for the use case |
| **Vertical scaling** | DB needs more RAM/CPU now, quick fix | Buying time before a proper solution | As a permanent solution — it has a ceiling |
| **Table partitioning** | Large table, range-based queries slow | Table > 10M rows, queries filter on a range column | Low-cardinality keys, random access patterns |
| **Partial index** | Low-cardinality column with skewed queries | `WHERE status = 'pending'` hits < 5% of rows | High-cardinality columns (use regular index) |
| **Covering index** | Frequent queries that fetch the same small set of columns | High-traffic list endpoints (GET /claims) | Wide rows — INCLUDE columns inflate index size |
| **Cache-aside** | Repeated reads of the same data | Data changes infrequently, stale-for-seconds is acceptable | Financial transactions, strong consistency required |
| **Sharding** | Single node cannot hold the data or write throughput | Multi-TB datasets, write throughput > 10k TPS | Small-to-medium datasets — adds enormous complexity |

---

## Repository structure

```
phase-8b-db-scaling/
├── pgbouncer/
│   └── pgbouncer-values.yaml          ← Bitnami PgBouncer Helm values (pool size, mode, timeouts)
├── postgres/
│   ├── replica-values.yaml            ← Bitnami PostgreSQL Helm values (replication enabled)
│   ├── partitioning.sql               ← Range partition migration for the claims table
│   ├── indexes.sql                    ← Partial, covering, GIN indexes with EXPLAIN output
│   └── slow-queries.sql               ← pg_stat_statements queries for finding bottlenecks
└── redis/
    └── cache-aside-example.py         ← Refined cache-aside: per-member keys, TTL by data type, warm-up
```

---

## Prerequisites

Phase 4 (PostgreSQL + Redis running), Phase 8 (HPA in place):

```bash
kubectl get pods -l app.kubernetes.io/name=postgresql
kubectl get pods -l app.kubernetes.io/name=redis
kubectl get hpa
```

---

## Step 1 — Enable pg_stat_statements and find the bottlenecks

Before touching the schema or adding hardware, identify the actual bottlenecks.

```bash
# Connect to PostgreSQL
kubectl exec -it postgresql-0 -- psql -U coverline -d coverline
```

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

Run the slow query analysis from `postgres/slow-queries.sql`:

```bash
kubectl exec -it postgresql-0 -- psql -U coverline -d coverline \
  -f /dev/stdin < phase-8b-db-scaling/postgres/slow-queries.sql
```

**Read the output before doing anything else.** The goal is to fix the queries consuming the most total time — not the slowest individual query. A query taking 1200ms called 14 times is less important than a query taking 38ms called 2.8 million times.

Check connection saturation:

```sql
SELECT state, COUNT(*) FROM pg_stat_activity
WHERE datname = 'coverline' GROUP BY state;
```

If you see more than 80% of `max_connections` used, or any `idle in transaction` connections lasting more than 30 seconds — connection pooling is the first fix.

---

## Step 2 — Install PgBouncer

PgBouncer is the single highest-impact change for a connection-saturated PostgreSQL instance. It costs almost nothing (32 MiB RAM) and typically reduces DB CPU by 30–50% immediately.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm upgrade --install pgbouncer bitnami/pgbouncer \
  --namespace default \
  --values phase-8b-db-scaling/pgbouncer/pgbouncer-values.yaml \
  --wait
```

### Pool modes explained

| Mode | Connection returned to pool | Use when |
|---|---|---|
| **Session** | When client disconnects | App uses `SET`, advisory locks, or `LISTEN/NOTIFY` |
| **Transaction** | After each `COMMIT` or `ROLLBACK` | Stateless apps — use this (default for CoverLine) |
| **Statement** | After each statement | Rarely — breaks multi-statement transactions |

CoverLine uses **transaction mode**. The Flask backend opens a connection, runs a transaction, commits, and releases — PgBouncer immediately returns that connection to the pool for the next request.

### Update the backend to connect via PgBouncer

Update the `DB_HOST` environment variable (via Vault or Helm values):

```bash
# Before: DB_HOST=postgresql
# After:  DB_HOST=pgbouncer

helm upgrade coverline phase-4-helm/charts/backend/ \
  --reuse-values \
  --set env.DB_HOST=pgbouncer
```

### Verify the connection count dropped

```bash
# Wait 60 seconds after rollout
kubectl exec -it postgresql-0 -- psql -U coverline -d coverline \
  -c "SELECT state, COUNT(*) FROM pg_stat_activity
      WHERE datname = 'coverline' GROUP BY state;"
```

Expected: connections drop from 180 to ~25 (PgBouncer pool size + admin).

### PgBouncer stats

```bash
# Connect to PgBouncer admin interface
kubectl exec -it deploy/pgbouncer -- psql -p 6432 -U pgbouncer pgbouncer

SHOW POOLS;
-- cl_active: clients actively running a query
-- cl_waiting: clients waiting for a pool connection (should be 0)
-- sv_active: real server connections in use
-- sv_idle: real server connections in pool, idle

SHOW STATS;
-- total_requests, avg_query_us (microseconds per query)
```

If `cl_waiting` is consistently > 0, increase `defaultPoolSize` in the Helm values.

---

## Step 3 — Add a read replica

The primary is still handling all reads. Route SELECT traffic to a standby.

```bash
helm upgrade postgresql bitnami/postgresql \
  --namespace default \
  --values phase-8b-db-scaling/postgres/replica-values.yaml \
  --reuse-values \
  --wait
```

This creates:
- `postgresql-primary-0` — accepts reads and writes
- `postgresql-read-0` — accepts reads only (hot standby)

### Verify replication is running

```bash
# On primary — check replication slot
kubectl exec -it postgresql-primary-0 -- psql -U postgres \
  -c "SELECT client_addr, state, sent_lsn, write_lsn, replay_lsn,
             (sent_lsn - replay_lsn) AS replication_lag_bytes
      FROM pg_stat_replication;"

# On replica — confirm it is in recovery
kubectl exec -it postgresql-read-0 -- psql -U postgres \
  -c "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"
# Expected: pg_is_in_recovery = t
```

### Route reads to the replica

Install a second PgBouncer pointing at the replica:

```bash
helm upgrade --install pgbouncer-replica bitnami/pgbouncer \
  --namespace default \
  --set postgresql.host=postgresql-read \
  --set pgbouncer.defaultPoolSize=10 \
  --set pgbouncer.poolMode=transaction
```

Update the backend to use `DB_READ_HOST=pgbouncer-replica` for SELECT queries:

```python
# backend app.py — route by query type
import os

db_write = connect(host=os.getenv("DB_HOST"))         # pgbouncer → primary
db_read  = connect(host=os.getenv("DB_READ_HOST"))    # pgbouncer-replica → replica

@app.route("/claims/<int:member_id>")
def get_claims(member_id):
    # Read replica — acceptable replication lag for a list endpoint
    cur = db_read.cursor()
    cur.execute("SELECT ... FROM claims WHERE member_id = %s", (member_id,))
    ...

@app.route("/claims", methods=["POST"])
def create_claim():
    # Primary only — writes must be strongly consistent
    cur = db_write.cursor()
    cur.execute("INSERT INTO claims ...", ...)
    ...
```

### Replication lag monitoring

Replication lag means the replica is behind the primary. A member who submits a claim and immediately refreshes the list might not see it — the replica hasn't caught up yet.

```bash
# Add to PrometheusRule
- alert: PostgreSQLReplicationLagHigh
  expr: pg_replication_lag_seconds > 5
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "PostgreSQL replication lag > 5s — read replica may serve stale data"
```

**When replication lag is unacceptable** (e.g. financial confirmation page immediately after a write), route that specific endpoint to the primary. Don't route everything to the primary — that defeats the purpose.

---

## Step 4 — Partition the claims table

The `claims` table has 8 million rows. A query filtering by `status` does a full table scan. Partitioning by quarter means the planner only reads the relevant child table.

> Run during a low-traffic window. Estimated duration: 15–30 minutes for 8M rows.

```bash
kubectl exec -it postgresql-primary-0 -- psql -U coverline -d coverline \
  -f /dev/stdin < phase-8b-db-scaling/postgres/partitioning.sql
```

### Verify partition pruning

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, member_id, amount FROM claims
WHERE created_at >= '2026-01-01' AND created_at < '2026-04-01';
```

Look for in the output:

```
Partitions selected: 1 out of 10
  ->  Seq Scan on claims_2026_q1
```

Before partitioning this was a full scan of all 8M rows. Now it scans ~500k rows.

### Use pg_partman for automated partition creation

```sql
CREATE EXTENSION pg_partman;

SELECT partman.create_parent(
  p_parent_table => 'public.claims',
  p_control      => 'created_at',
  p_type         => 'range',
  p_interval     => '3 months',
  p_premake      => 4
);
```

Schedule maintenance via a Kubernetes CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-partman-maintenance
spec:
  schedule: "0 2 * * 0"   # every Sunday at 02:00 UTC
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: psql
              image: bitnami/postgresql:16
              command:
                - psql
                - -h
                - postgresql-primary
                - -U
                - coverline
                - -d
                - coverline
                - -c
                - "SELECT partman.run_maintenance();"
          restartPolicy: OnFailure
```

---

## Step 5 — Add indexes

Run the index strategy from `postgres/indexes.sql`:

```bash
kubectl exec -it postgresql-primary-0 -- psql -U coverline -d coverline \
  -f /dev/stdin < phase-8b-db-scaling/postgres/indexes.sql
```

### EXPLAIN ANALYZE before and after

**Before** (full table scan):

```
Seq Scan on claims  (cost=0.00..185432.00 rows=62400 width=92)
                    (actual time=0.14..1203.45 rows=62400 loops=1)
  Filter: ((status)::text = 'pending'::text)
  Rows Removed by Filter: 7937600
Planning Time: 0.8 ms
Execution Time: 1231.2 ms
```

**After** (partial index):

```
Index Scan using idx_claims_pending on claims  (cost=0.42..2840.33 rows=62400 width=92)
                                               (actual time=0.08..7.32 rows=62400 loops=1)
Planning Time: 0.6 ms
Execution Time: 7.9 ms
```

**156× faster.** No schema change, no application change.

### Monitor index usage

```sql
SELECT indexname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes
WHERE tablename = 'claims'
ORDER BY idx_scan DESC;
```

Any index with `idx_scan = 0` after a week of normal traffic is unused — drop it. Unused indexes consume disk space and slow down every INSERT and UPDATE.

---

## Step 6 — Refine the cache-aside pattern

Phase 4 cached all claims under a single key (`claims:all`) with a 30-second TTL. At 300,000 members this caused **cache stampedes**: when the key expired, all 20 backend pods queried the database simultaneously.

The refined pattern in `redis/cache-aside-example.py`:

- **Per-member keys** (`claims:member:<id>`) — invalidating one member's data doesn't affect others
- **Write-through invalidation** — `DELETE claims:member:<id>` immediately on POST, rather than waiting for TTL
- **TTL by data type** — member claims: 5 minutes; dashboard aggregate: 60 seconds (stale is acceptable)
- **Startup warm-up** — pre-populate the top 1000 most active members to avoid a cold-start stampede

```bash
# Monitor cache hit rate
kubectl exec -it redis-master-0 -- redis-cli INFO stats | grep -E "keyspace_hits|keyspace_misses"
```

Target: **> 80% hit rate** on `GET /claims/<member_id>`. Below 80%, most requests are hitting the DB — check key TTL and whether invalidation is working correctly.

---

## Step 7 — Verify the full stack

```bash
# PgBouncer pool stats
kubectl exec -it deploy/pgbouncer -- psql -p 6432 -U pgbouncer pgbouncer -c "SHOW POOLS;"

# Connection count on primary (should be ≤ 25)
kubectl exec -it postgresql-primary-0 -- psql -U postgres \
  -c "SELECT state, COUNT(*) FROM pg_stat_activity WHERE datname='coverline' GROUP BY state;"

# Replication lag
kubectl exec -it postgresql-primary-0 -- psql -U postgres \
  -c "SELECT client_addr, (sent_lsn - replay_lsn) AS lag_bytes FROM pg_stat_replication;"

# Top queries after optimisation
kubectl exec -it postgresql-primary-0 -- psql -U coverline -d coverline \
  -c "SELECT LEFT(query,60), calls, ROUND(mean_exec_time::numeric,1) AS mean_ms
      FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 5;"

# Redis hit rate
kubectl exec -it redis-master-0 -- redis-cli INFO stats | \
  grep -E "keyspace_hits|keyspace_misses"
```

### Before vs after

| Metric | Before | After |
|---|---|---|
| DB connections at peak | 183 | 22 |
| DB CPU at peak | 97% | 38% |
| P95 query latency (`pending` claims) | 1,231ms | 8ms |
| P95 query latency (`member_id` lookup) | 38ms | 4ms |
| Cache hit rate | 40% (single key) | 84% (per-member keys) |
| Queries hitting DB per second | 2,400 | 380 |

---

## Architecture Decision Records

- `docs/decisions/adr-025-pgbouncer-transaction-mode.md` — Why transaction pooling over session pooling, and which app features break in transaction mode
- `docs/decisions/adr-026-read-replica-routing.md` — Which endpoints route to replica vs primary, and the replication lag tolerance per endpoint
- `docs/decisions/adr-027-range-partitioning-quarterly.md` — Why quarterly over monthly partitions, and the pg_partman maintenance strategy

---

## Teardown

PgBouncer and the replica are running costs. Tear down between lab sessions:

```bash
helm uninstall pgbouncer pgbouncer-replica

# Downgrade PostgreSQL back to standalone
helm upgrade postgresql bitnami/postgresql \
  --reuse-values \
  --set architecture=standalone
```

---

## Cost breakdown

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| postgresql-primary PVC (20Gi) | ~$0.07 |
| postgresql-replica PVC (20Gi) | ~$0.07 |
| PgBouncer pods (2 × minimal) | included in node cost |
| **Phase 8b additional cost** | **~$0.14** |

---

## Production considerations

### 1. Never skip connection pooling
The first sign of DB trouble in a Kubernetes cluster is almost always connection exhaustion — HPA adds pods, each pod opens connections, the DB runs out. PgBouncer is a 32 MiB fix that scales to thousands of app connections. Install it before you need it.

### 2. Replication lag is a product decision, not a technical one
A read replica serving stale data for 2–3 seconds is acceptable on a claims list page. It is not acceptable on a payment confirmation page. Work with product to classify each endpoint by consistency requirement — then route accordingly. Don't default everything to primary "to be safe".

### 3. Add partitions before you need them
Partitioning a live table with 50M rows takes hours and requires a maintenance window. The right time to partition is when the table hits 5–10M rows — before query latency becomes noticeable. Use pg_partman so future partitions are created automatically.

### 4. One index per query, not one query per index
Every index slows down INSERT and UPDATE. Add an index only after `pg_stat_statements` shows a specific query with high total time and an EXPLAIN that shows a Seq Scan. Don't add indexes speculatively — measure first.

### 5. Cache invalidation is the hard part
Cache-aside is simple to implement. The bugs come from invalidation: forgetting to delete a key after a write, deleting the wrong key, or invalidating too aggressively and removing the cache benefit. Write unit tests for every invalidation path.

---

[Back to main README](../README.md) | [Previous: Phase 8 — Advanced Kubernetes](../phase-8-advanced-k8s/README.md)
