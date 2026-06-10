-- ============================================================================
-- BCDR DEMO — CLEANUP
-- ============================================================================
--
-- Purpose : Drops all demo objects created by 01–06 scripts.
--           Run sections in order: PRIMARY then SECONDARY.
--
-- ⚠  THIS IS DESTRUCTIVE — all BCDR_DEMO data will be permanently deleted.
--    Only run this when tearing down the demo environment.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  PART 1 — Run on SNOW_BCDR_PRIMARY first                               ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- ─────────────────────────────────────────────────────────────────────────────

USE ROLE ACCOUNTADMIN;

SELECT '=== CLEANUP — PRIMARY ===' AS STEP, CURRENT_ACCOUNT() AS ACCOUNT;

-- Step 1a: Drop the failover group (must be done before dropping the database)
-- This also removes the replica on the secondary automatically.
DROP FAILOVER GROUP IF EXISTS BCDR_FG;

-- Step 1b: Drop the connection object
DROP CONNECTION IF EXISTS BCDR_CONNECTION;

-- Step 1c: Drop the Git repository and secret
DROP GIT REPOSITORY IF EXISTS BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO;
DROP SECRET         IF EXISTS BCDR_DEMO.OPERATIONAL.BCDR_GITHUB_PAT;

-- Step 1d: Drop the database (cascades to all schemas, tables, views,
--          dynamic tables, streamlit apps, and stages within it)
DROP DATABASE IF EXISTS BCDR_DEMO;

-- Step 1e: Drop the warehouse
DROP WAREHOUSE IF EXISTS BCDR_WH;

-- Step 1f: Drop roles (bottom-up to avoid dependency errors)
REVOKE ROLE BCDR_ANALYST FROM ROLE BCDR_ADMIN;
REVOKE ROLE BCDR_ADMIN   FROM ROLE ACCOUNTADMIN;
DROP ROLE IF EXISTS BCDR_ANALYST;
DROP ROLE IF EXISTS BCDR_ADMIN;

-- Verify cleanup
SHOW DATABASES    LIKE 'BCDR%';
SHOW WAREHOUSES   LIKE 'BCDR%';
SHOW ROLES        LIKE 'BCDR%';
SHOW CONNECTIONS  LIKE 'BCDR%';
SHOW FAILOVER GROUPS;

SELECT '=== PRIMARY CLEANUP COMPLETE ===' AS STATUS, CURRENT_TIMESTAMP() AS TS;

-- ─────────────────────────────────────────────────────────────────────────────
-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  PART 2 — Run on SNOW_BCDR_SECONDARY (only if replica still exists)    ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Dropping the failover group on PRIMARY (Step 1a above) should cascade and
-- drop the replica on secondary automatically. Run this section only if the
-- secondary replica persists after primary cleanup.
-- ─────────────────────────────────────────────────────────────────────────────

-- USE ROLE ACCOUNTADMIN;   -- switch to SNOW_BCDR_SECONDARY

-- SELECT '=== CLEANUP — SECONDARY ===' AS STEP, CURRENT_ACCOUNT() AS ACCOUNT;

-- DROP FAILOVER GROUP IF EXISTS BCDR_FG;
-- DROP DATABASE       IF EXISTS BCDR_DEMO;

-- SHOW DATABASES    LIKE 'BCDR%';
-- SHOW FAILOVER GROUPS;

-- SELECT '=== SECONDARY CLEANUP COMPLETE ===' AS STATUS, CURRENT_TIMESTAMP() AS TS;
