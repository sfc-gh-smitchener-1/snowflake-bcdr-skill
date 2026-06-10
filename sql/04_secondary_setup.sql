-- ============================================================================
-- BCDR DEMO — SECONDARY ACCOUNT SETUP
-- ============================================================================
--
-- Account : SFSENORTHAMERICA.SNOW_BCDR_SECONDARY (OZC55031, us-east-1)
-- Purpose : Creates the replica failover group on the secondary account,
--           performs the initial sync, and validates replicated objects.
--
-- Run as  : ACCOUNTADMIN on the SECONDARY account
-- Prereq  : 03_failover_group.sql must be complete on PRIMARY
--
-- ⚠  Run this script on the SECONDARY account, not the primary.
--    Connection: SNOW_BCDR_SECONDARY
-- ============================================================================

USE ROLE ACCOUNTADMIN;

SELECT
    '=== BCDR DEMO — SECONDARY SETUP ===' AS STEP,
    CURRENT_TIMESTAMP()                    AS STARTED_AT,
    CURRENT_ACCOUNT()                      AS ACCOUNT,
    CURRENT_REGION()                       AS REGION;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1: CREATE THE REPLICA FAILOVER GROUP
-- ─────────────────────────────────────────────────────────────────────────────
-- This registers the secondary account as a replica target.
-- The BCDR_DEMO database will be created automatically upon first REFRESH.

CREATE FAILOVER GROUP IF NOT EXISTS BCDR_FG
    AS REPLICA OF SFSENORTHAMERICA.SNOW_BCDR_PRIMARY.BCDR_FG;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2: INITIAL DATA SYNC (manual refresh)
-- ─────────────────────────────────────────────────────────────────────────────
-- The scheduled auto-refresh kicks in after 10 minutes, but we trigger
-- an immediate refresh for the demo so BCDR_DEMO appears right away.
--
-- This can take 30–120 seconds depending on data volume.

ALTER FAILOVER GROUP BCDR_FG REFRESH;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3: VALIDATE REPLICATED OBJECTS
-- ─────────────────────────────────────────────────────────────────────────────

-- Confirm failover group shows as REPLICA
SHOW FAILOVER GROUPS;

-- Confirm BCDR_DEMO database now exists on secondary
SHOW DATABASES LIKE 'BCDR_DEMO';

-- Confirm tables are present and row counts match primary
SELECT 'CUSTOMERS'    AS OBJECT, COUNT(*) AS ROWS FROM BCDR_DEMO.OPERATIONAL.CUSTOMERS
UNION ALL
SELECT 'PRODUCTS'     AS OBJECT, COUNT(*) AS ROWS FROM BCDR_DEMO.OPERATIONAL.PRODUCTS
UNION ALL
SELECT 'ORDERS'       AS OBJECT, COUNT(*) AS ROWS FROM BCDR_DEMO.OPERATIONAL.ORDERS
UNION ALL
SELECT 'TRANSACTIONS' AS OBJECT, COUNT(*) AS ROWS FROM BCDR_DEMO.OPERATIONAL.TRANSACTIONS;

-- Confirm Dynamic Table replicated
SHOW DYNAMIC TABLES IN SCHEMA BCDR_DEMO.ANALYTICS;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4: GRANT READ ACCESS ON SECONDARY
-- ─────────────────────────────────────────────────────────────────────────────
-- The BCDR_ANALYST role was replicated from primary.
-- Grant it to any secondary-account users who need read access during DR.

-- Example: grant replicated role to a local user
-- GRANT ROLE BCDR_ANALYST TO USER <secondary_user>;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5: CHECK REPLICATION LAG
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    REPLICATION_GROUP_NAME,
    PHASE_TIME                          AS LAST_REFRESH_TIME,
    TIMEDIFF('minute',
        PHASE_TIME,
        CURRENT_TIMESTAMP())            AS LAG_MINUTES,
    OBJECTS_UPDATED,
    BYTES_TRANSFERRED
FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_REFRESH_HISTORY
WHERE REPLICATION_GROUP_NAME = 'BCDR_FG'
  AND PHASE = 'COMPLETED'
ORDER BY PHASE_TIME DESC
LIMIT 5;

SELECT '=== 04 SECONDARY SETUP COMPLETE ===' AS STATUS,
       CURRENT_TIMESTAMP()                    AS COMPLETED_AT;

-- ─────────────────────────────────────────────────────────────────────────────
-- NOTES ON READ-ONLY VS FAILOVER
-- ─────────────────────────────────────────────────────────────────────────────
-- While this account is SECONDARY:
--   • BCDR_DEMO is READ-ONLY (DML will fail with "object is replicated")
--   • All SELECT queries work normally — good for DR reporting
--   • Refreshes happen every 10 min (scheduled) or on-demand via REFRESH
--
-- To promote this account to PRIMARY (actual failover), see:
--   05_connection_failover.sql → then run:
--   ALTER FAILOVER GROUP BCDR_FG PRIMARY;
--
-- Next: run 05_connection_failover.sql on the PRIMARY account.
