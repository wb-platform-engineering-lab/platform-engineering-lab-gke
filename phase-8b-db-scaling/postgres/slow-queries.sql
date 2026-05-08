-- =============================================================================
-- Phase 8b — Database Scaling: Slow Query Analysis
-- =============================================================================
-- pg_stat_statements tracks execution statistics for every query.
-- Enable it once, then query it to find the top offenders.
-- =============================================================================

-- Step 1: Enable pg_stat_statements (requires DB restart on first enable)
-- ---------------------------------------------------------------------------
-- Add to postgresql.conf:
--   shared_preload_libraries = 'pg_stat_statements'
--   pg_stat_statements.max = 10000
--   pg_stat_statements.track = all
--
-- On Bitnami PostgreSQL Helm chart:
--   primary.extendedConfiguration: |
--     shared_preload_libraries = 'pg_stat_statements'
--     pg_stat_statements.track = all

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- =============================================================================
-- Step 2: Find the top 10 slowest queries by mean execution time
-- =============================================================================

SELECT
    LEFT(query, 80)                                         AS query_snippet,
    calls,
    ROUND(mean_exec_time::numeric, 2)                       AS mean_ms,
    ROUND(total_exec_time::numeric, 2)                      AS total_ms,
    ROUND((total_exec_time / SUM(total_exec_time) OVER ()
           * 100)::numeric, 2)                              AS pct_total_time,
    ROUND(stddev_exec_time::numeric, 2)                     AS stddev_ms,
    rows / NULLIF(calls, 0)                                 AS avg_rows
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY mean_exec_time DESC
LIMIT 10;

-- =============================================================================
-- Step 3: Find queries with the highest total time (most impactful to fix)
-- =============================================================================

SELECT
    LEFT(query, 100)                                        AS query_snippet,
    calls,
    ROUND(total_exec_time::numeric / 1000, 2)               AS total_seconds,
    ROUND(mean_exec_time::numeric, 2)                       AS mean_ms,
    ROUND(min_exec_time::numeric, 2)                        AS min_ms,
    ROUND(max_exec_time::numeric, 2)                        AS max_ms
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- =============================================================================
-- Step 4: Find N+1 query patterns (high call count, low rows returned)
-- =============================================================================
-- N+1 queries have: many calls, 1 row per call, no cache hit.
-- Fix: JOIN in the application layer or use a batch endpoint.

SELECT
    LEFT(query, 100)                                        AS query_snippet,
    calls,
    rows / NULLIF(calls, 0)                                 AS avg_rows_per_call,
    ROUND(mean_exec_time::numeric, 2)                       AS mean_ms
FROM pg_stat_statements
WHERE rows / NULLIF(calls, 0) <= 1
  AND calls > 1000
ORDER BY calls DESC
LIMIT 10;

-- =============================================================================
-- Step 5: EXPLAIN ANALYZE a specific slow query
-- =============================================================================
-- Run EXPLAIN (ANALYZE, BUFFERS) to see:
--   - Seq Scan vs Index Scan (Seq Scan on large tables = problem)
--   - actual rows vs estimated rows (large diff = stale statistics)
--   - Buffers: hit vs read (low hit ratio = cache miss, disk I/O)

EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT id, member_id, amount, status, created_at
FROM claims
WHERE member_id = 12345
  AND status = 'pending'
ORDER BY created_at DESC
LIMIT 20;

-- What to look for:
--   Seq Scan      → add an index
--   rows=8000000  → partition the table
--   Buffers: read=50000, hit=200  → data not in shared_buffers, increase shared_buffers
--   actual rows=20000 vs estimated rows=1  → run ANALYZE claims to update statistics

-- =============================================================================
-- Step 6: Check connection saturation
-- =============================================================================

-- Current connections by state
SELECT
    state,
    COUNT(*)                                                AS connections,
    MAX(EXTRACT(EPOCH FROM (NOW() - state_change)))::INT    AS max_age_seconds
FROM pg_stat_activity
WHERE datname = 'coverline'
GROUP BY state
ORDER BY connections DESC;

-- Idle-in-transaction connections (the worst kind — hold locks)
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    EXTRACT(EPOCH FROM (NOW() - state_change))::INT         AS idle_seconds,
    LEFT(query, 80)                                         AS last_query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND datname = 'coverline'
ORDER BY idle_seconds DESC;

-- Maximum connections vs current usage
SELECT
    MAX(setting::int)                                       AS max_connections,
    COUNT(pid)                                              AS current_connections,
    ROUND(COUNT(pid)::numeric / MAX(setting::int) * 100, 1) AS pct_used
FROM pg_settings, pg_stat_activity
WHERE name = 'max_connections';

-- =============================================================================
-- Step 7: Reset statistics after fixing queries (start fresh)
-- =============================================================================
-- SELECT pg_stat_statements_reset();
-- SELECT pg_stat_reset();
