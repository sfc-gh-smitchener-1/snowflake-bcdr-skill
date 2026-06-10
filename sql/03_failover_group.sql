-- ============================================================================
-- BCDR DEMO — FAILOVER GROUP (PRIMARY ACCOUNT)
-- ============================================================================
--
-- Account : SFSENORTHAMERICA.SNOW_BCDR_PRIMARY (OAB74379, us-west-2)
-- Purpose : Creates a Failover Group that replicates BCDR_DEMO and account-
--           level objects to the secondary account in us-east-1.
--           This enables both replication (read-only DR) and failover
--           (promote secondary to primary for true BC).
--
-- Run as  : ACCOUNTADMIN on the PRIMARY account
-- Prereq  : 01_primary_setup.sql → 02_git_integration.sql
--
-- Objects created:
--   Failover Group : BCDR_FG  (PRIMARY role — this account)
--
-- After this script, run 04_secondary_setup.sql on the SECONDARY account.
-- ============================================================================

USE ROLE ACCOUNTADMIN;

SELECT
    '=== BCDR DEMO — FAILOVER GROUP SETUP ===' AS STEP,
    CURRENT_TIMESTAMP()                          AS STARTED_AT,
    CURRENT_ACCOUNT()                            AS ACCOUNT,
    CURRENT_REGION()                             AS REGION;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1: CREATE THE FAILOVER GROUP
-- ─────────────────────────────────────────────────────────────────────────────
-- OBJECT_TYPES controls what is replicated:
--   DATABASES          → BCDR_DEMO (tables, views, dynamic tables, schemas)
--   WAREHOUSES         → BCDR_WH
--   ROLES              → BCDR_ADMIN, BCDR_ANALYST and their hierarchy
--   RESOURCE MONITORS  → Any resource monitors in the account
--   INTEGRATIONS       → GIT_API (API integration)
--   NETWORK POLICIES   → Any network policies
--
-- REPLICATION SCHEDULE = '10 MINUTE'
--   Snowflake automatically refreshes the secondary every 10 minutes.
--   For a live demo you can also trigger manual refreshes (see 07_validate).
--
-- NOTE: The following are NOT replicated and must be recreated manually
--   on the secondary if failover occurs:
--   • External stages (credentials don't replicate)
--   • Pipes (stateful — offset is lost)
--   • Streams (offset-based — must reset after failover)
--   • Tasks (replicated as suspended; enable manually post-failover)

CREATE FAILOVER GROUP IF NOT EXISTS BCDR_FG
    OBJECT_TYPES             = DATABASES,
                               WAREHOUSES,
                               ROLES,
                               RESOURCE MONITORS,
                               INTEGRATIONS,
                               NETWORK POLICIES
    ALLOWED_DATABASES        = BCDR_DEMO
    ALLOWED_INTEGRATION_TYPES = API INTEGRATIONS,
                                SECURITY INTEGRATIONS
    REPLICATION SCHEDULE     = '10 MINUTE'
    ALLOWED_ACCOUNTS         = SFSENORTHAMERICA.SNOW_BCDR_SECONDARY;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2: VERIFY THE FAILOVER GROUP
-- ─────────────────────────────────────────────────────────────────────────────

SHOW FAILOVER GROUPS;

-- Confirm this account holds the PRIMARY role
SELECT
    "name"                     AS FAILOVER_GROUP,
    "type"                     AS TYPE,
    "status"                   AS STATUS,
    "databases"                AS REPLICATED_DATABASES,
    "allowed_accounts"         AS ALLOWED_ACCOUNTS,
    "replication_schedule"     AS SCHEDULE,
    "created_on"               AS CREATED_ON
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3: MONITOR REPLICATION STATUS
-- ─────────────────────────────────────────────────────────────────────────────
-- After the secondary creates its replica (script 04), use these queries
-- to monitor replication health.

-- Most recent refresh history (run after secondary replica is created)
-- SELECT *
-- FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_REFRESH_HISTORY
-- WHERE REPLICATION_GROUP_NAME = 'BCDR_FG'
-- ORDER BY PHASE_TIME DESC
-- LIMIT 20;

-- Live refresh progress (run during an active refresh)
-- SELECT *
-- FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_PROGRESS('BCDR_FG'));

-- Check replication lag (bytes transferred, credits consumed)
-- SELECT *
-- FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_USAGE_HISTORY
-- WHERE REPLICATION_GROUP_NAME = 'BCDR_FG'
-- ORDER BY START_TIME DESC
-- LIMIT 10;

SELECT '=== 03 FAILOVER GROUP CREATED ===' AS STATUS,
       CURRENT_TIMESTAMP()                  AS COMPLETED_AT;

-- ─────────────────────────────────────────────────────────────────────────────
-- NEXT STEP
-- ─────────────────────────────────────────────────────────────────────────────
-- Switch to the SECONDARY account (SFSENORTHAMERICA.SNOW_BCDR_SECONDARY)
-- and run: 04_secondary_setup.sql
