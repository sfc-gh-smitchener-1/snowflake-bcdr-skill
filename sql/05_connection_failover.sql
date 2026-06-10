-- ============================================================================
-- BCDR DEMO — CONNECTION OBJECT & CLIENT FAILOVER
-- ============================================================================
--
-- Account : Run PART 1 on SNOW_BCDR_PRIMARY, PART 2 on SNOW_BCDR_SECONDARY
-- Purpose : Creates a Snowflake Connection object that provides a single
--           stable hostname for clients. When failover occurs, clients
--           automatically re-route to the promoted account with no
--           connection string changes.
--
-- Prereq  : 04_secondary_setup.sql must be complete
--
-- Objects created:
--   Connection : BCDR_CONNECTION  (PRIMARY role — created on primary)
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  PART 1 — Run on SNOW_BCDR_PRIMARY (OAB74379, us-west-2)               ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- ─────────────────────────────────────────────────────────────────────────────

USE ROLE ACCOUNTADMIN;

SELECT
    '=== PART 1: PRIMARY — CONNECTION SETUP ===' AS STEP,
    CURRENT_TIMESTAMP()                           AS STARTED_AT,
    CURRENT_ACCOUNT()                             AS ACCOUNT;

-- Create the Connection on the primary account
-- This generates a stable <org>-<connection>.snowflakecomputing.com URL
CREATE CONNECTION IF NOT EXISTS BCDR_CONNECTION
    COMMENT = 'BCDR demo connection — provides transparent client redirect on failover.';

-- Enable failover: allow the secondary account to be promoted
ALTER CONNECTION BCDR_CONNECTION
    ENABLE FAILOVER TO ACCOUNTS SFSENORTHAMERICA.SNOW_BCDR_SECONDARY;

-- Verify
SHOW CONNECTIONS;

SELECT
    "name"             AS CONNECTION_NAME,
    "account_name"     AS CURRENT_PRIMARY,
    "failover_allowed" AS FAILOVER_ENABLED,
    "connection_url"   AS CLIENT_URL
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- ─────────────────────────────────────────────────────────────────────────────
-- CLIENT CONNECTION STRINGS
-- ─────────────────────────────────────────────────────────────────────────────
-- Replace <org> with: SFSENORTHAMERICA
-- The connection URL format is: <org>-<connection_name>.snowflakecomputing.com
--
-- Python (Snowpark / snowflake-connector-python):
--   connection_params = {
--       "account":    "sfsenorthamerica-bcdr_connection",
--       "user":       "<user>",
--       "password":   "<password>",
--       "role":       "BCDR_ANALYST",
--       "warehouse":  "BCDR_WH",
--       "database":   "BCDR_DEMO"
--   }
--
-- JDBC:
--   jdbc:snowflake://sfsenorthamerica-bcdr_connection.snowflakecomputing.com/
--
-- SnowSQL:
--   snowsql -a sfsenorthamerica-bcdr_connection
--
-- Clients using this URL always connect to whoever is currently PRIMARY.
-- No reconfiguration needed after a failover.

-- ─────────────────────────────────────────────────────────────────────────────
-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  PART 2 — Run on SNOW_BCDR_SECONDARY (OZC55031, us-east-1)             ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- ─────────────────────────────────────────────────────────────────────────────
-- After the above runs, switch to the secondary account and confirm
-- the connection is visible there too.

-- USE ROLE ACCOUNTADMIN;   -- on SECONDARY

-- SHOW CONNECTIONS;        -- should show BCDR_CONNECTION with PRIMARY = OAB74379

-- ─────────────────────────────────────────────────────────────────────────────
-- FAILOVER PROCEDURE (run on SECONDARY when primary is unavailable)
-- ─────────────────────────────────────────────────────────────────────────────
-- This promotes the secondary to PRIMARY. All write traffic routes here.
-- Only run this during an actual DR event or planned failover test.
--
--   USE ROLE ACCOUNTADMIN;  -- on SECONDARY
--   ALTER FAILOVER GROUP BCDR_FG PRIMARY;
--
-- After promotion, clients using BCDR_CONNECTION auto-redirect within ~30s.
-- BCDR_DEMO becomes writable on the (now) primary secondary account.

-- ─────────────────────────────────────────────────────────────────────────────
-- FAILBACK PROCEDURE (run on original PRIMARY once it recovers)
-- ─────────────────────────────────────────────────────────────────────────────
-- 1. On the original primary (now acting as secondary), refresh to catch up:
--    ALTER FAILOVER GROUP BCDR_FG REFRESH;
--
-- 2. Once data is in sync, promote the original primary back:
--    ALTER FAILOVER GROUP BCDR_FG PRIMARY;
--    (Run on SNOW_BCDR_PRIMARY — OAB74379)
--
-- 3. Verify clients are routing to the original primary again via SHOW CONNECTIONS.

SELECT '=== 05 CONNECTION FAILOVER SETUP COMPLETE ===' AS STATUS,
       CURRENT_TIMESTAMP()                              AS COMPLETED_AT;
