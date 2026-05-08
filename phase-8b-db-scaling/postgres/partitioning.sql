-- =============================================================================
-- Phase 8b — Database Scaling: Table Partitioning
-- =============================================================================
-- The claims table has grown to 8 million rows. Full table scans on status
-- and date range filters take 1.2 seconds. Partitioning by quarter reduces
-- the scan target to ~500k rows — the planner only reads relevant partitions.
--
-- Strategy: range partitioning on created_at (quarterly)
-- Why quarterly: claims are primarily queried by recent period (current quarter
-- open, last quarter pending). Older partitions are read-only and can be
-- moved to cheaper storage or archived.
--
-- Run as the coverline DB superuser.
-- =============================================================================

-- Step 1: Rename the existing table and create the partitioned parent
-- ---------------------------------------------------------------------------
-- In production, do this during a maintenance window with replication lag
-- monitoring. Use pg_partman for automated partition management.

BEGIN;

-- Rename original table to preserve data during migration
ALTER TABLE claims RENAME TO claims_legacy;

-- Create the new partitioned table with identical schema
CREATE TABLE claims (
    id          SERIAL,
    member_id   INTEGER      NOT NULL,
    amount      NUMERIC(10,2) NOT NULL,
    description TEXT,
    status      VARCHAR(20)  NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, created_at)   -- partition key must be in PK
) PARTITION BY RANGE (created_at);

-- Step 2: Create quarterly partitions
-- ---------------------------------------------------------------------------
-- Naming convention: claims_YYYY_QN
-- Each partition holds ~500k rows at current growth rate.

CREATE TABLE claims_2024_q1 PARTITION OF claims
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');

CREATE TABLE claims_2024_q2 PARTITION OF claims
    FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');

CREATE TABLE claims_2024_q3 PARTITION OF claims
    FOR VALUES FROM ('2024-07-01') TO ('2024-10-01');

CREATE TABLE claims_2024_q4 PARTITION OF claims
    FOR VALUES FROM ('2024-10-01') TO ('2025-01-01');

CREATE TABLE claims_2025_q1 PARTITION OF claims
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');

CREATE TABLE claims_2025_q2 PARTITION OF claims
    FOR VALUES FROM ('2025-04-01') TO ('2025-07-01');

CREATE TABLE claims_2025_q3 PARTITION OF claims
    FOR VALUES FROM ('2025-07-01') TO ('2025-10-01');

CREATE TABLE claims_2025_q4 PARTITION OF claims
    FOR VALUES FROM ('2025-10-01') TO ('2026-01-01');

CREATE TABLE claims_2026_q1 PARTITION OF claims
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');

CREATE TABLE claims_2026_q2 PARTITION OF claims
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');

-- Default partition catches anything outside defined ranges
-- Remove this in production once all ranges are covered
CREATE TABLE claims_default PARTITION OF claims DEFAULT;

-- Step 3: Migrate data from legacy table
-- ---------------------------------------------------------------------------
INSERT INTO claims SELECT * FROM claims_legacy;

-- Step 4: Verify row counts match
-- ---------------------------------------------------------------------------
SELECT
    'legacy'    AS source, COUNT(*) FROM claims_legacy
UNION ALL
SELECT
    'partitioned', COUNT(*) FROM claims;

COMMIT;

-- Step 5: Drop legacy table after verification (separate transaction)
-- ---------------------------------------------------------------------------
-- DROP TABLE claims_legacy;

-- =============================================================================
-- Verify partition pruning is working
-- =============================================================================

-- This query should hit only claims_2026_q1 — check with EXPLAIN
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT id, member_id, amount, status
FROM claims
WHERE created_at >= '2026-01-01'
  AND created_at <  '2026-04-01'
  AND status = 'pending';

-- Look for: "Partitions selected: 1" in the output
-- Before partitioning: Seq Scan on claims (cost=0.00..180000.00 rows=8000000)
-- After partitioning:  Seq Scan on claims_2026_q1 (cost=0.00..11000.00 rows=500000)

-- =============================================================================
-- Automate future partitions with pg_partman (recommended for production)
-- =============================================================================
-- CREATE EXTENSION pg_partman;
--
-- SELECT partman.create_parent(
--   p_parent_table  => 'public.claims',
--   p_control       => 'created_at',
--   p_type          => 'range',
--   p_interval      => '3 months',
--   p_premake       => 4   -- pre-create 4 future partitions
-- );
--
-- Then schedule: SELECT partman.run_maintenance();
-- via pg_cron or a Kubernetes CronJob.
