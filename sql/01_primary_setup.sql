-- ============================================================================
-- BCDR DEMO — PRIMARY ACCOUNT SETUP
-- ============================================================================
--
-- Account : SFSENORTHAMERICA.SNOW_BCDR_PRIMARY (OAB74379, us-west-2)
-- Purpose : Creates the demo database, roles, warehouse, and seed data
--           that will be replicated to the secondary account.
--
-- Run as  : ACCOUNTADMIN on the PRIMARY account
-- Run before: 02_git_integration.sql → 03_failover_group.sql
--
-- Objects created:
--   Roles       : BCDR_ADMIN, BCDR_ANALYST
--   Warehouse   : BCDR_WH
--   Database    : BCDR_DEMO
--   Schemas     : OPERATIONAL, ANALYTICS, STREAMLIT
--   Tables      : CUSTOMERS, ORDERS, TRANSACTIONS
--   View        : VW_ORDER_SUMMARY
--   Dynamic Tbl : AGG_DAILY_REVENUE
-- ============================================================================

USE ROLE ACCOUNTADMIN;

SELECT
    '=== BCDR DEMO — PRIMARY SETUP ===' AS STEP,
    CURRENT_TIMESTAMP()                 AS STARTED_AT,
    CURRENT_ACCOUNT()                   AS ACCOUNT,
    CURRENT_REGION()                    AS REGION;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1: ROLES
-- ─────────────────────────────────────────────────────────────────────────────

CREATE ROLE IF NOT EXISTS BCDR_ADMIN
    COMMENT = 'Administers BC/DR objects, replication, and failover operations.';

CREATE ROLE IF NOT EXISTS BCDR_ANALYST
    COMMENT = 'Read-only access to BCDR_DEMO for validation and reporting.';

-- Role hierarchy: ACCOUNTADMIN > BCDR_ADMIN > BCDR_ANALYST
GRANT ROLE BCDR_ADMIN   TO ROLE ACCOUNTADMIN;
GRANT ROLE BCDR_ANALYST TO ROLE BCDR_ADMIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2: WAREHOUSE
-- ─────────────────────────────────────────────────────────────────────────────

CREATE WAREHOUSE IF NOT EXISTS BCDR_WH
    WAREHOUSE_SIZE    = 'X-SMALL'
    AUTO_SUSPEND      = 60
    AUTO_RESUME       = TRUE
    COMMENT           = 'Warehouse for BCDR demo queries and Dynamic Table refresh.';

GRANT USAGE ON WAREHOUSE BCDR_WH TO ROLE BCDR_ADMIN;
GRANT USAGE ON WAREHOUSE BCDR_WH TO ROLE BCDR_ANALYST;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3: DATABASE AND SCHEMAS
-- ─────────────────────────────────────────────────────────────────────────────

CREATE DATABASE IF NOT EXISTS BCDR_DEMO
    DATA_RETENTION_TIME_IN_DAYS = 1
    COMMENT = 'BC/DR demo database — replicated to SNOW_BCDR_SECONDARY via failover group.';

CREATE SCHEMA IF NOT EXISTS BCDR_DEMO.OPERATIONAL
    COMMENT = 'Live transactional data — source of truth.';

CREATE SCHEMA IF NOT EXISTS BCDR_DEMO.ANALYTICS
    COMMENT = 'Derived and aggregated objects (Dynamic Tables, Views).';

CREATE SCHEMA IF NOT EXISTS BCDR_DEMO.STREAMLIT
    COMMENT = 'Stage and app objects for the BC/DR Streamlit dashboard.';

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4: TABLES
-- ─────────────────────────────────────────────────────────────────────────────

USE ROLE BCDR_ADMIN;
USE DATABASE BCDR_DEMO;
USE WAREHOUSE BCDR_WH;

CREATE TABLE IF NOT EXISTS BCDR_DEMO.OPERATIONAL.CUSTOMERS (
    CUSTOMER_ID     NUMBER        NOT NULL PRIMARY KEY,
    FIRST_NAME      VARCHAR(50)   NOT NULL,
    LAST_NAME       VARCHAR(50)   NOT NULL,
    EMAIL           VARCHAR(100),
    REGION          VARCHAR(20),
    TIER            VARCHAR(20)   DEFAULT 'STANDARD',
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS BCDR_DEMO.OPERATIONAL.PRODUCTS (
    PRODUCT_ID      NUMBER        NOT NULL PRIMARY KEY,
    PRODUCT_NAME    VARCHAR(100)  NOT NULL,
    CATEGORY        VARCHAR(50),
    UNIT_PRICE      NUMBER(10, 2) NOT NULL,
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS BCDR_DEMO.OPERATIONAL.ORDERS (
    ORDER_ID        NUMBER        NOT NULL PRIMARY KEY,
    CUSTOMER_ID     NUMBER        NOT NULL REFERENCES BCDR_DEMO.OPERATIONAL.CUSTOMERS(CUSTOMER_ID),
    ORDER_DATE      DATE          NOT NULL,
    STATUS          VARCHAR(20)   DEFAULT 'PENDING',
    TOTAL_AMOUNT    NUMBER(12, 2),
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS BCDR_DEMO.OPERATIONAL.TRANSACTIONS (
    TRANSACTION_ID  NUMBER        NOT NULL PRIMARY KEY,
    ORDER_ID        NUMBER        NOT NULL REFERENCES BCDR_DEMO.OPERATIONAL.ORDERS(ORDER_ID),
    AMOUNT          NUMBER(10, 2) NOT NULL,
    PAYMENT_METHOD  VARCHAR(30),
    PROCESSED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5: SEED DATA
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO BCDR_DEMO.OPERATIONAL.CUSTOMERS
    (CUSTOMER_ID, FIRST_NAME, LAST_NAME, EMAIL, REGION, TIER)
SELECT seq4() + 1, v:fn::STRING, v:ln::STRING, v:em::STRING, v:rg::STRING, v:ti::STRING
FROM (
    SELECT PARSE_JSON(c) AS v FROM (VALUES
        ('{"fn":"Alice","ln":"Johnson","em":"alice@example.com","rg":"US-WEST","ti":"GOLD"}'),
        ('{"fn":"Bob","ln":"Smith","em":"bob@example.com","rg":"US-EAST","ti":"STANDARD"}'),
        ('{"fn":"Carol","ln":"Williams","em":"carol@example.com","rg":"EU-WEST","ti":"PLATINUM"}'),
        ('{"fn":"David","ln":"Brown","em":"david@example.com","rg":"US-WEST","ti":"STANDARD"}'),
        ('{"fn":"Eva","ln":"Davis","em":"eva@example.com","rg":"AP-SOUTH","ti":"GOLD"}'),
        ('{"fn":"Frank","ln":"Miller","em":"frank@example.com","rg":"US-EAST","ti":"STANDARD"}'),
        ('{"fn":"Grace","ln":"Wilson","em":"grace@example.com","rg":"EU-WEST","ti":"PLATINUM"}'),
        ('{"fn":"Henry","ln":"Moore","em":"henry@example.com","rg":"US-WEST","ti":"STANDARD"}'),
        ('{"fn":"Irene","ln":"Taylor","em":"irene@example.com","rg":"US-EAST","ti":"GOLD"}'),
        ('{"fn":"Jack","ln":"Anderson","em":"jack@example.com","rg":"AP-SOUTH","ti":"STANDARD"}')
    ) t(c)
);

INSERT INTO BCDR_DEMO.OPERATIONAL.PRODUCTS
    (PRODUCT_ID, PRODUCT_NAME, CATEGORY, UNIT_PRICE)
VALUES
    (1, 'Enterprise License',   'SOFTWARE',  4999.00),
    (2, 'Pro License',          'SOFTWARE',  1499.00),
    (3, 'Support Package - Gold','SERVICES',  2000.00),
    (4, 'Training Bundle',      'SERVICES',   500.00),
    (5, 'Connector Plugin',     'SOFTWARE',   299.00);

INSERT INTO BCDR_DEMO.OPERATIONAL.ORDERS
    (ORDER_ID, CUSTOMER_ID, ORDER_DATE, STATUS, TOTAL_AMOUNT)
VALUES
    (1001, 1, CURRENT_DATE - 10, 'COMPLETED', 4999.00),
    (1002, 2, CURRENT_DATE -  9, 'COMPLETED', 1499.00),
    (1003, 3, CURRENT_DATE -  8, 'COMPLETED', 7000.00),
    (1004, 4, CURRENT_DATE -  7, 'PENDING',   1798.00),
    (1005, 5, CURRENT_DATE -  6, 'COMPLETED', 2000.00),
    (1006, 1, CURRENT_DATE -  5, 'COMPLETED',  500.00),
    (1007, 6, CURRENT_DATE -  4, 'PROCESSING', 299.00),
    (1008, 7, CURRENT_DATE -  3, 'COMPLETED', 9999.00),
    (1009, 8, CURRENT_DATE -  2, 'COMPLETED', 4999.00),
    (1010, 9, CURRENT_DATE -  1, 'PENDING',   1499.00);

INSERT INTO BCDR_DEMO.OPERATIONAL.TRANSACTIONS
    (TRANSACTION_ID, ORDER_ID, AMOUNT, PAYMENT_METHOD)
VALUES
    (9001, 1001, 4999.00, 'CREDIT_CARD'),
    (9002, 1002, 1499.00, 'WIRE_TRANSFER'),
    (9003, 1003, 7000.00, 'WIRE_TRANSFER'),
    (9005, 1005, 2000.00, 'CREDIT_CARD'),
    (9006, 1006,  500.00, 'CREDIT_CARD'),
    (9008, 1008, 9999.00, 'WIRE_TRANSFER'),
    (9009, 1009, 4999.00, 'ACH');

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 6: VIEW AND DYNAMIC TABLE (ANALYTICS LAYER)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW BCDR_DEMO.ANALYTICS.VW_ORDER_SUMMARY AS
SELECT
    o.ORDER_ID,
    o.ORDER_DATE,
    o.STATUS,
    o.TOTAL_AMOUNT,
    c.FIRST_NAME || ' ' || c.LAST_NAME AS CUSTOMER_NAME,
    c.REGION,
    c.TIER
FROM BCDR_DEMO.OPERATIONAL.ORDERS    o
JOIN BCDR_DEMO.OPERATIONAL.CUSTOMERS c ON c.CUSTOMER_ID = o.CUSTOMER_ID;

CREATE OR REPLACE DYNAMIC TABLE BCDR_DEMO.ANALYTICS.AGG_DAILY_REVENUE
    TARGET_LAG    = '1 hour'
    WAREHOUSE     = BCDR_WH
    COMMENT       = 'Daily revenue aggregation — auto-refreshed, included in failover group.'
AS
SELECT
    o.ORDER_DATE,
    c.REGION,
    COUNT(DISTINCT o.ORDER_ID)      AS ORDER_COUNT,
    SUM(o.TOTAL_AMOUNT)             AS TOTAL_REVENUE,
    AVG(o.TOTAL_AMOUNT)             AS AVG_ORDER_VALUE
FROM BCDR_DEMO.OPERATIONAL.ORDERS    o
JOIN BCDR_DEMO.OPERATIONAL.CUSTOMERS c ON c.CUSTOMER_ID = o.CUSTOMER_ID
WHERE o.STATUS = 'COMPLETED'
GROUP BY o.ORDER_DATE, c.REGION;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 7: GRANTS
-- ─────────────────────────────────────────────────────────────────────────────

GRANT USAGE  ON DATABASE BCDR_DEMO TO ROLE BCDR_ADMIN;
GRANT USAGE  ON DATABASE BCDR_DEMO TO ROLE BCDR_ANALYST;

GRANT USAGE  ON ALL SCHEMAS IN DATABASE BCDR_DEMO TO ROLE BCDR_ADMIN;
GRANT USAGE  ON ALL SCHEMAS IN DATABASE BCDR_DEMO TO ROLE BCDR_ANALYST;

GRANT SELECT ON ALL TABLES  IN DATABASE BCDR_DEMO TO ROLE BCDR_ANALYST;
GRANT SELECT ON ALL VIEWS   IN DATABASE BCDR_DEMO TO ROLE BCDR_ANALYST;
GRANT SELECT ON ALL DYNAMIC TABLES IN DATABASE BCDR_DEMO TO ROLE BCDR_ANALYST;

GRANT ALL    ON ALL TABLES  IN DATABASE BCDR_DEMO TO ROLE BCDR_ADMIN;
GRANT ALL    ON ALL SCHEMAS IN DATABASE BCDR_DEMO TO ROLE BCDR_ADMIN;

-- Future grants
GRANT SELECT ON FUTURE TABLES        IN DATABASE BCDR_DEMO TO ROLE BCDR_ANALYST;
GRANT SELECT ON FUTURE VIEWS         IN DATABASE BCDR_DEMO TO ROLE BCDR_ANALYST;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN DATABASE BCDR_DEMO TO ROLE BCDR_ANALYST;

-- ─────────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ─────────────────────────────────────────────────────────────────────────────

SELECT 'CUSTOMERS'    AS obj, COUNT(*) AS rows FROM BCDR_DEMO.OPERATIONAL.CUSTOMERS
UNION ALL
SELECT 'PRODUCTS'     AS obj, COUNT(*) AS rows FROM BCDR_DEMO.OPERATIONAL.PRODUCTS
UNION ALL
SELECT 'ORDERS'       AS obj, COUNT(*) AS rows FROM BCDR_DEMO.OPERATIONAL.ORDERS
UNION ALL
SELECT 'TRANSACTIONS' AS obj, COUNT(*) AS rows FROM BCDR_DEMO.OPERATIONAL.TRANSACTIONS;

SELECT '=== 01 PRIMARY SETUP COMPLETE ===' AS STATUS,
       CURRENT_TIMESTAMP()                  AS COMPLETED_AT;
