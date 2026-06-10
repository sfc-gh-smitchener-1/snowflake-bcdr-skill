-- ============================================================================
-- BCDR DEMO — ENABLE REPLICATION / FAILOVER (ORG-LEVEL PREREQUISITE)
-- ============================================================================
--
-- Org      : SFSENORTHAMERICA
-- Accounts : SNOW_BCDR_PRIMARY   (OAB74379, us-west-2)  — source / primary
--            SNOW_BCDR_SECONDARY (OZC55031, us-east-1)  — target / secondary
--
-- Purpose  : Before any failover group can be created (03) or replicated (04),
--            an ORGADMIN must explicitly enable replication on BOTH accounts.
--            Skipping this step is the #1 cause of "CREATE FAILOVER GROUP" and
--            secondary REFRESH failures.
--
-- Run as   : ORGADMIN (run ONCE for the whole org — covers both accounts)
-- Run before: 01_primary_setup.sql
--
-- Requirements:
--   • Both accounts must be Business Critical Edition (or higher). Failover
--     groups (account-object replication + failover) are not available on
--     Standard/Enterprise.
--   • You must hold the ORGADMIN role. If it isn't enabled, an existing
--     ACCOUNTADMIN can self-grant it:  GRANT ROLE ORGADMIN TO USER <you>;
-- ============================================================================

USE ROLE ORGADMIN;

SELECT
    '=== BCDR DEMO — ENABLE REPLICATION (ORGADMIN) ===' AS STEP,
    CURRENT_TIMESTAMP()                                 AS STARTED_AT,
    CURRENT_ROLE()                                      AS ROLE;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1: PRE-FLIGHT — list org accounts and confirm edition + region
-- ─────────────────────────────────────────────────────────────────────────────
-- Confirm both accounts are present and that EDITION is BUSINESS_CRITICAL (or
-- higher). Note the exact account_name values for the enablement calls below.

SHOW ORGANIZATION ACCOUNTS;

SELECT
    "account_name"     AS ACCOUNT_NAME,
    "edition"          AS EDITION,
    "snowflake_region" AS REGION,
    "account_locator"  AS LOCATOR
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "account_name" IN ('SNOW_BCDR_PRIMARY', 'SNOW_BCDR_SECONDARY')
ORDER BY "account_name";

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2: ENABLE REPLICATION FOR EACH ACCOUNT
-- ─────────────────────────────────────────────────────────────────────────────
-- Call once per account using the ORG_NAME.ACCOUNT_NAME identifier.
-- Use the name (not the legacy account locator) — locators can collide across
-- regions and cause the wrong account to be enabled.
-- This also enables Client Redirect (needed for the CONNECTION object in 05).

SELECT SYSTEM$GLOBAL_ACCOUNT_SET_PARAMETER(
    'SFSENORTHAMERICA.SNOW_BCDR_PRIMARY',
    'ENABLE_ACCOUNT_DATABASE_REPLICATION',
    'true'
);

SELECT SYSTEM$GLOBAL_ACCOUNT_SET_PARAMETER(
    'SFSENORTHAMERICA.SNOW_BCDR_SECONDARY',
    'ENABLE_ACCOUNT_DATABASE_REPLICATION',
    'true'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3: VERIFY
-- ─────────────────────────────────────────────────────────────────────────────
-- Both accounts should appear with is_org_admin/region info. If an account is
-- missing here, the enablement above did not take effect — re-check the name.

SHOW REPLICATION ACCOUNTS;

SELECT
    "account_name"     AS ACCOUNT_NAME,
    "snowflake_region" AS REGION,
    "account_locator"  AS LOCATOR
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "account_name" IN ('SNOW_BCDR_PRIMARY', 'SNOW_BCDR_SECONDARY')
ORDER BY "account_name";

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4 (OPTIONAL): ACCOUNT-LEVEL REPLICATION TUNING
-- ─────────────────────────────────────────────────────────────────────────────
-- Run these as ACCOUNTADMIN on EACH account (not ORGADMIN). They are optional
-- but commonly set for real BC/DR. Left commented for the demo.
--
-- USE ROLE ACCOUNTADMIN;
--
-- -- Guardrail against an unexpectedly huge initial replication (TB). Raise as
-- -- needed; the first refresh fails if the primary exceeds this limit.
-- ALTER ACCOUNT SET INITIAL_REPLICATION_SIZE_LIMIT_IN_TB = 5;
--
-- -- Give long initial refreshes room to complete (seconds).
-- ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS = 14400;

SELECT '=== 00 REPLICATION ENABLED ===' AS STATUS,
       CURRENT_TIMESTAMP()              AS COMPLETED_AT;

-- ─────────────────────────────────────────────────────────────────────────────
-- NEXT STEP
-- ─────────────────────────────────────────────────────────────────────────────
-- On the PRIMARY account (SNOW_BCDR_PRIMARY), run: 01_primary_setup.sql
-- ============================================================================
