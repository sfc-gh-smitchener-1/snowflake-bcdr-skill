-- ============================================================================
-- BCDR DEMO — STREAMLIT DASHBOARD DEPLOYMENT
-- ============================================================================
--
-- Account : SFSENORTHAMERICA.SNOW_BCDR_PRIMARY (OAB74379, us-west-2)
-- Purpose : Deploys the BC/DR status dashboard as a Streamlit in Snowflake
--           app, sourced directly from the Git repository.
--
-- Run as  : ACCOUNTADMIN on the PRIMARY account
-- Prereq  : 02_git_integration.sql (BCDR_DEMO_REPO must exist and be fetched)
--
-- Objects created:
--   Stage     : BCDR_DEMO.STREAMLIT.APP_STAGE
--   Streamlit : BCDR_DEMO.STREAMLIT.BCDR_DASHBOARD
-- ============================================================================

USE ROLE    ACCOUNTADMIN;
USE DATABASE BCDR_DEMO;
USE SCHEMA   BCDR_DEMO.STREAMLIT;
USE WAREHOUSE BCDR_WH;

SELECT
    '=== BCDR DEMO — STREAMLIT DEPLOYMENT ===' AS STEP,
    CURRENT_TIMESTAMP()                         AS STARTED_AT,
    CURRENT_ACCOUNT()                           AS ACCOUNT;

-- ─────────────────────────────────────────────────────────────────────────────
-- OPTION A: DEPLOY FROM GIT REPOSITORY (recommended)
-- ─────────────────────────────────────────────────────────────────────────────
-- References bcdr_dashboard.py directly from the Snowflake branch of the
-- Git repo. Any push to the branch is reflected after ALTER ... FETCH.

CREATE OR REPLACE STREAMLIT BCDR_DEMO.STREAMLIT.BCDR_DASHBOARD
    ROOT_LOCATION = '@BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO/branches/Snowflake/BCDR/streamlit'
    MAIN_FILE     = 'bcdr_dashboard.py'
    QUERY_WAREHOUSE = BCDR_WH
    COMMENT       = 'BC/DR Status Dashboard — shows replication health, lag, and failover controls.';

-- ─────────────────────────────────────────────────────────────────────────────
-- OPTION B: DEPLOY FROM INTERNAL STAGE (fallback if Git repo not configured)
-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Create a stage:
--    CREATE STAGE IF NOT EXISTS BCDR_DEMO.STREAMLIT.APP_STAGE
--        DIRECTORY = (ENABLE = TRUE);
--
-- 2. Upload the app file from your local machine (SnowSQL or Snowsight):
--    PUT file:///path/to/BCDR/streamlit/bcdr_dashboard.py
--        @BCDR_DEMO.STREAMLIT.APP_STAGE
--        AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
--
-- 3. Create the Streamlit app pointing to the stage:
--    CREATE OR REPLACE STREAMLIT BCDR_DEMO.STREAMLIT.BCDR_DASHBOARD
--        ROOT_LOCATION = '@BCDR_DEMO.STREAMLIT.APP_STAGE'
--        MAIN_FILE     = 'bcdr_dashboard.py'
--        QUERY_WAREHOUSE = BCDR_WH;

-- ─────────────────────────────────────────────────────────────────────────────
-- GRANTS
-- ─────────────────────────────────────────────────────────────────────────────

GRANT USAGE ON SCHEMA   BCDR_DEMO.STREAMLIT               TO ROLE BCDR_ADMIN;
GRANT USAGE ON SCHEMA   BCDR_DEMO.STREAMLIT               TO ROLE BCDR_ANALYST;
GRANT USAGE ON STREAMLIT BCDR_DEMO.STREAMLIT.BCDR_DASHBOARD TO ROLE BCDR_ADMIN;
GRANT USAGE ON STREAMLIT BCDR_DEMO.STREAMLIT.BCDR_DASHBOARD TO ROLE BCDR_ANALYST;

-- ─────────────────────────────────────────────────────────────────────────────
-- GRANT ACCOUNT_USAGE ACCESS (needed for replication history charts)
-- ─────────────────────────────────────────────────────────────────────────────

GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE BCDR_ADMIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ─────────────────────────────────────────────────────────────────────────────

SHOW STREAMLITS IN SCHEMA BCDR_DEMO.STREAMLIT;

-- Get the app URL
SELECT
    "name"        AS APP_NAME,
    "url_id"      AS URL_ID,
    'https://app.snowflake.com/' AS BASE_URL,
    "created_on"  AS CREATED_ON
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SELECT '=== 06 STREAMLIT DEPLOYED ===' AS STATUS,
       CURRENT_TIMESTAMP()              AS COMPLETED_AT;

-- ─────────────────────────────────────────────────────────────────────────────
-- UPDATING THE APP
-- ─────────────────────────────────────────────────────────────────────────────
-- After pushing changes to GitHub, re-fetch and the app picks up automatically:
--
--   ALTER GIT REPOSITORY BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO FETCH;
--
-- No redeploy needed when using Git-backed Streamlit (Option A).
