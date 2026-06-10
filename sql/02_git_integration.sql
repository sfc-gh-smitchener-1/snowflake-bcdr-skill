-- ============================================================================
-- BCDR DEMO — GIT REPOSITORY INTEGRATION
-- ============================================================================
--
-- Account : SFSENORTHAMERICA.SNOW_BCDR_PRIMARY (OAB74379, us-west-2)
-- Purpose : Connects the Snowflake-dca-fullstack-demo GitHub repo to
--           Snowflake as a Git Repository object so scripts and notebooks
--           can be opened directly from Workspaces.
--
-- Run as  : ACCOUNTADMIN on the PRIMARY account
-- Prereq  : 01_primary_setup.sql must be complete
--           GIT_API integration already exists in this account
--
-- Objects created:
--   Secret      : BCDR_DEMO.OPERATIONAL.BCDR_GITHUB_PAT
--   Git Repo    : BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO
--
-- ⚠  BEFORE RUNNING: replace <YOUR_GITHUB_PAT> below with a GitHub
--    Personal Access Token (classic or fine-grained) that has read access
--    to the sfc-gh-smitchener-1/snowflake-dca-fullstack-demo repo.
--    Generate one at: https://github.com/settings/tokens
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE BCDR_DEMO;
USE SCHEMA   BCDR_DEMO.OPERATIONAL;
USE WAREHOUSE BCDR_WH;

SELECT
    '=== BCDR DEMO — GIT INTEGRATION ===' AS STEP,
    CURRENT_TIMESTAMP()                    AS STARTED_AT,
    CURRENT_ACCOUNT()                      AS ACCOUNT;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1: VERIFY THE EXISTING GIT_API INTEGRATION
-- ─────────────────────────────────────────────────────────────────────────────
-- GIT_API was pre-created in this account and allows https://github.com/
-- No changes needed — just confirm it is enabled.

DESCRIBE API INTEGRATION GIT_API;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2: CREATE A SECRET FOR GITHUB AUTHENTICATION
-- ─────────────────────────────────────────────────────────────────────────────
-- Store your GitHub PAT as a Snowflake secret so credentials are never
-- exposed in SQL history or logs.
--
-- Replace <YOUR_GITHUB_USERNAME> and <YOUR_GITHUB_PAT> before executing.

CREATE SECRET IF NOT EXISTS BCDR_DEMO.OPERATIONAL.BCDR_GITHUB_PAT
    TYPE                = PASSWORD
    USERNAME            = '<YOUR_GITHUB_USERNAME>'
    PASSWORD            = '<YOUR_GITHUB_PAT>'
    COMMENT             = 'GitHub PAT for sfc-gh-smitchener-1/snowflake-dca-fullstack-demo';

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3: CREATE THE GIT REPOSITORY OBJECT
-- ─────────────────────────────────────────────────────────────────────────────

CREATE GIT REPOSITORY IF NOT EXISTS BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO
    API_INTEGRATION = GIT_API
    GIT_CREDENTIALS = BCDR_DEMO.OPERATIONAL.BCDR_GITHUB_PAT
    ORIGIN          = 'https://github.com/sfc-gh-smitchener-1/snowflake-dca-fullstack-demo.git'
    COMMENT         = 'DCA Full Stack Demo repo — Snowflake branch. Used for BCDR demo scripts and Streamlit app.';

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4: FETCH LATEST COMMITS
-- ─────────────────────────────────────────────────────────────────────────────
-- Syncs the local Git metadata cache with GitHub.

ALTER GIT REPOSITORY BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO FETCH;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5: VERIFY BRANCHES AND FILES
-- ─────────────────────────────────────────────────────────────────────────────

SHOW GIT BRANCHES IN GIT REPOSITORY BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO;

-- List files on the Snowflake branch
LS @BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO/branches/Snowflake/;

-- List the SQL scripts in the repo
LS @BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO/branches/Snowflake/sql/;

-- List the Streamlit files
LS @BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO/branches/Snowflake/streamlit/;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 6: EXECUTE A SCRIPT DIRECTLY FROM GIT (optional demo step)
-- ─────────────────────────────────────────────────────────────────────────────
-- You can run any .sql file from the repo directly without downloading it:
--
--   EXECUTE IMMEDIATE FROM
--     @BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO/branches/Snowflake/sql/01_setup.sql;
--
-- This is the key demo point: scripts are sourced from Git, not copy-pasted.

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 7: GRANTS
-- ─────────────────────────────────────────────────────────────────────────────

GRANT READ ON GIT REPOSITORY BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO TO ROLE BCDR_ADMIN;
GRANT USAGE ON SECRET         BCDR_DEMO.OPERATIONAL.BCDR_GITHUB_PAT TO ROLE BCDR_ADMIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- WORKSPACE SETUP INSTRUCTIONS
-- ─────────────────────────────────────────────────────────────────────────────
-- To open and edit repo files in a Snowflake Workspace (Notebook/Worksheet):
--
--   1. In Snowsight, go to Projects → Notebooks (or Worksheets)
--   2. Click + New Notebook → "From Git Repository"
--   3. Select repository : BCDR_DEMO.OPERATIONAL.BCDR_DEMO_REPO
--   4. Select branch     : Snowflake
--   5. Select file       : any .ipynb or .sql file
--
-- Changes made in the Workspace can be committed back to GitHub
-- using the Git panel (push / pull / branch) within Snowsight.

SELECT '=== 02 GIT INTEGRATION COMPLETE ===' AS STATUS,
       CURRENT_TIMESTAMP()                    AS COMPLETED_AT;
