# Meridian Financial Snowflake DR Failover / Failback Runbook
### Business Critical Edition · AWS (MERIDIAN_PROD, us-east-1) ⇄ us-west-2 (MERIDIAN_DR)
### Two Modes: Mode A — Real DR Drill (destructive) · Mode B — Non-Destructive Test (clone-and-test, recommended first)

> **⚠ Fictional enablement example.** Meridian Financial / "Helios" is invented. See [`README.md`](./README.md).
>
> **Scope.** DR for the Helios workload (`HELIOS_ANALYTICS_PROD`) only. Other applications on `MERIDIAN_PROD` have **no DR plan** and **must not be disrupted** by a Helios failover. This is the central design constraint.
>
> **Companion documents.** [`Meridian-DR-Summary.md`](./Meridian-DR-Summary.md) · [`Meridian-DR-Best-Practices.md`](./Meridian-DR-Best-Practices.md)

---

## 0. Why this document exists

Helios is a tenant on a **shared** `MERIDIAN_PROD` account. It needs regional DR, but the other databases on the account do not. The runbook lets Helios fail over to us-west-2 **independently**, while leaving every non-Helios workload read-write on production.

Independent failover groups make that possible:

| Group | Members | Promoted during a Helios failover? |
|---|---|---|
| `FG_ACCOUNT_LEVEL` | Users, roles, warehouses, resource monitors, network policies, integrations | **Yes** |
| `FG_HELIOS_DB` | `HELIOS_ANALYTICS_PROD` + dependent objects | **Yes** |
| `FG_NON_HELIOS_DBS` | All other in-scope production databases | **No** (stays on production) |

Two wrinkles:
1. **Client Redirect via a named Connection** (`HELIOS_CONN` → `MERIDIAN-HELIOS_CONN.snowflakecomputing.com`) gives consumers a stable URL — **but only if every writer is migrated to it first.**
2. **AWS PrivateLink breaks automatic redirect.** Every failover needs a **manual DNS change** (connection URL **and** OCSP URL), the dominant RTO component.

---

## 1. Helios Environment Reference

### 1.1 How failover scoping works (why other workloads keep running)

Common question: *"When Helios fails over and DR becomes primary, won't the rest of the production account go read-only?"* **No.**

**`PRIMARY` / `SECONDARY` is a property of a failover group and its member objects — not of the account.** There is no operation that fails an *account* over as a whole. `ALTER FAILOVER GROUP <fg> PRIMARY` changes the role of **only the objects that are members of that group**. One account can be primary for some groups, secondary for others, and the sole owner of databases in **no** group at all.

A database in no failover group is purely local: never replicated, never has a secondary copy, never touched by any failover command. Promoting a group on DR does **not** demote production.

**Post-failover state on production** (after promoting `FG_ACCOUNT_LEVEL` + `FG_HELIOS_DB` on DR):

| Object on production | Member of a promoted group? | Role after promotion | Read/Write on production? |
|---|---|---|---|
| `HELIOS_ANALYTICS_PROD` | Yes (`FG_HELIOS_DB`) | becomes **secondary** | Read-only |
| Databases in `FG_NON_HELIOS_DBS` | No (group not promoted) | stays **primary** | **Read/Write** |
| Databases in **no** failover group | n/a | unchanged | **Read/Write** |
| Roles / users / warehouses (`FG_ACCOUNT_LEVEL`) | Yes | becomes **secondary** | See caveat below |

> **⚠ Cross-tenant caveat — account-level objects.** `FG_ACCOUNT_LEVEL` replicates account-level object *types* (roles, users, warehouses, …) **account-wide as a set** — you cannot cherry-pick Helios's roles. When promoted to DR, **all** roles/users/warehouses on production become **read-only for administration** (no `CREATE`/`ALTER`/`DROP`). **However**, existing warehouses keep running, grants keep working, and **queries/DML against read-write databases continue normally**. The impact is administrative DDL — **not** data read/write.
>
> **Design implication.** If a non-Helios team must create/modify roles or warehouses *during* a failover window, that is the one operation this design blocks. The alternative is to maintain account objects on DR via IaC instead of a failover group — at the cost of more setup and drift management. Confirm stakeholders accept the administrative freeze, or choose the IaC route.

### 1.2 Account inventory (confirm placeholder values)

| Component | Value | Notes |
|---|---|---|
| Edition | **Business Critical** *(confirm)* | Required for Failover Groups + Client Redirect |
| Cloud | **AWS** | — |
| Primary region | AWS `us-east-1` | Production account |
| DR region | AWS `us-west-2` | Must differ from primary |
| Org | `MERIDIAN` | Same org for both accounts |
| Account locator — Primary | `MERIDIAN_PROD` | — |
| Account locator — DR | `MERIDIAN_DR` | us-west-2 |
| Workload database | `HELIOS_ANALYTICS_PROD` | — |
| Connection object | `HELIOS_CONN` *(confirm)* | Client Redirect |
| Connection URL | `MERIDIAN-HELIOS_CONN.snowflakecomputing.com` | Helios consumers only |
| VPC endpoint — Primary | `vpce-helios-use1` | AWS PrivateLink |
| VPC endpoint — DR | `vpce-helios-usw2` | AWS PrivateLink |
| DNS TTL (connection + OCSP) | **60–300 seconds** | Set in advance |
| Failover group refresh interval | `10 MINUTE` *(confirm)* | Use SQL, not GUI |

> **Action.** Confirm the placeholder values; append the database list for `FG_NON_HELIOS_DBS`, the role/warehouse list for `FG_ACCOUNT_LEVEL`, and the dependent-object inventory for `FG_HELIOS_DB` before the first drill.

### 1.3 What is and is not replicated

| Object class | Replicates? | Action required |
|---|---|---|
| Permanent & transient tables | ✅ | Standard |
| Dynamic tables | ✅ | First refresh on DR is a full reinitialization |
| External stages | ✅ (definition) | Storage-integration trust must be pre-configured on DR |
| Internal stages | ✅ (caveats) | Directory table enabled to replicate files; **no file >5 GB** |
| Storage integrations | ✅ (object) | **DR service identity needs IAM role trust policy** on the same S3 buckets |
| Pipes / Snowpipe | ✅ (object) | **SNS topic + SQS queue + notification integration must be built on DR separately** |
| Streams (standard) | ✅ | Source must be in same group / database |
| **Streams (append-only)** | ❌ | **Resolve before the group is created — blocks refresh** |
| Tasks | ✅ | Must have run once; owning roles in `FG_ACCOUNT_LEVEL` |
| External tables | ❌ | **Skipped silently** — map dependencies |
| Hybrid tables | ❌ | Not supported |
| Event tables | ❌ | DMF results/history won't exist on DR |
| **Inbound datashare databases** | ❌ | **Auto-fulfillment or dual-share required (see §8)** |
| Masking / row-access policies | ✅ | — |
| Tags | ✅ | Cannot be modified on DR side |
| Stored procedures & UDFs | ✅ | Replicate any external-network integration too |
| Users / roles / warehouses / monitors / policies / integrations | ✅ (BC) | Covered by `FG_ACCOUNT_LEVEL` |

### 1.4 BCDR analytics: feeding the RPO/RTO analysis

The two DR targets are only as good as the data behind them:

- **RPO (Recovery Point Objective)** — *how much data can be lost?* Governed by the failover-group **refresh cadence** and **how fast each table changes** between refreshes.
- **RTO (Recovery Time Objective)** — *how long until writable on DR?* Driven by the **volume/volatility** of what must be promoted/reinitialized (Dynamic Tables fully reinitialize on first refresh), plus the **manual DNS/OCSP step** (§5–§6) and any **non-replicated objects** that must be rebuilt.

Measure the workload — don't assume. Run these on production during planning and re-run before each drill.

| Analytic | Reads from | Feeds | Why |
|---|---|---|---|
| **Table churn** (fail-safe ÷ active bytes) | `TABLE_STORAGE_METRICS` | **RPO + RTO** | High churn = more data at risk between refreshes and more to re-sync on recovery. Finds the hot tables. |
| **Database churn ratio** | `DATABASE_STORAGE_USAGE_HISTORY` | **RTO** | High DB-wide fail-safe-to-size ratio = volatile workload = longer recovery. |
| **Transient-table flag** | `TABLE_STORAGE_METRICS` (`IS_TRANSIENT`) | **RPO** | No fail-safe — changes lost since last refresh are unrecoverable. |
| **Replication volume + cost** | `DATABASE_REPLICATION_USAGE_HISTORY` | **RPO feasibility** | Whether a tighter cadence is sustainable, or churn must be reduced first. |
| **Refresh schedule** | `SHOW REPLICATION GROUPS` | **RPO (definition)** | The cadence on `FG_HELIOS_DB` *is* the worst-case RPO. |

#### 1.4.1 Per-table churn — the primary RPO/RTO driver

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §1.4.1 Hottest tables in HELIOS_ANALYTICS_PROD.
-- Churn % = failsafe / active * 100. High churn = high RPO exposure AND high RTO cost.
-- ═══════════════════════════════════════════════════════════════════════════
SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    IS_TRANSIENT,
    ACTIVE_BYTES,
    TIME_TRAVEL_BYTES,
    FAILSAFE_BYTES,
    ROUND(FAILSAFE_BYTES / NULLIF(ACTIVE_BYTES, 0) * 100, 1) AS CHURN_PCT
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_CATALOG = 'HELIOS_ANALYTICS_PROD'
  AND DELETED = FALSE
ORDER BY FAILSAFE_BYTES DESC
LIMIT 50;
```

**How it feeds the analysis.** Example: if `HELIOS_ANALYTICS_PROD.MART.FACT_TRADE_SETTLEMENT` shows a 55% churn rate and dwarfs every other table in fail-safe bytes, then (a) the achievable **RPO** is effectively dictated by how often that one table can be replicated, and (b) it is the long pole in **RTO** because its Dynamic Table consumers reinitialize from it after failover. A low-churn reference table like `REF.SECURITY_MASTER` is irrelevant to both; large tables with **zero** fail-safe are static and cheap to protect.

#### 1.4.2 Database-wide churn ratio — the RTO indicator

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §1.4.2 Workload volatility for HELIOS_ANALYTICS_PROD as a whole.
-- High failsafe-to-size ratio = volatile = longer recovery/re-stabilize after failover.
-- ═══════════════════════════════════════════════════════════════════════════
SELECT
    DATABASE_NAME,
    AVG(AVERAGE_DATABASE_BYTES) / POWER(1024,4) AS AVG_DB_TB,
    AVG(AVERAGE_FAILSAFE_BYTES) / POWER(1024,4) AS AVG_FAILSAFE_TB,
    ROUND(AVG(AVERAGE_FAILSAFE_BYTES) / NULLIF(AVG(AVERAGE_DATABASE_BYTES),0) * 100, 1) AS CHURN_RATIO_PCT
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
WHERE DATABASE_NAME = 'HELIOS_ANALYTICS_PROD'
  AND USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())
GROUP BY DATABASE_NAME;
```

**How it feeds the analysis.** Low `CHURN_RATIO_PCT` (<5%) supports an aggressive RTO; high (>30%) is the early warning that the proposed RTO is optimistic and the first drill should *measure* re-stabilization rather than assume it.

#### 1.4.3 Replication volume & cost — is the target RPO feasible?

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §1.4.3 The RPO target is only real if the refresh cadence is sustainable.
-- ═══════════════════════════════════════════════════════════════════════════
SHOW REPLICATION GROUPS;   -- inspect REPLICATION_SCHEDULE on FG_HELIOS_DB

SELECT
    DATABASE_NAME,
    SUM(CREDITS_USED)          AS TOTAL_REPLICATION_CREDITS,
    SUM(BYTES_TRANSFERRED)     AS TOTAL_BYTES_REPLICATED,
    COUNT(DISTINCT START_TIME) AS REPLICATION_EVENTS
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_REPLICATION_USAGE_HISTORY
WHERE DATABASE_NAME = 'HELIOS_ANALYTICS_PROD'
  AND START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY DATABASE_NAME;
```

**How it feeds the analysis.** If the business wants a 5-minute RPO but the §1.4.1 hot tables already make a 10-minute refresh expensive, this is the evidence for the trade-off: accept the cost of more frequent refreshes, or reduce churn (split `FACT_TRADE_SETTLEMENT`, lower its time-travel retention).

#### 1.4.4 Turning the analytics into DR tiers

| Tier | Defined by the analytics as | RPO/RTO treatment |
|---|---|---|
| **Tier 1 — Critical** | Highest churn **and** feeds Dynamic Tables / semantic views / shares (e.g., the settlement/position marts) | Drives the RPO target; row-count + checksum parity verified **first** after every refresh and post-failover |
| **Tier 2 — Important** | Hot (non-trivial churn) but no critical downstream | Verified in post-failover validation; churn watched for cost |
| **Tier 3 — Standard** | Cold / low churn / static reference data | Replicates with the group; spot-check only |
| **⚠ At-risk (any tier)** | `IS_TRANSIENT = TRUE`, or behind a replication gap — append-only streams, external/hybrid/event tables, inbound shares (§1.3, §8) | Highest RPO risk: resolve before the first drill. |

---

## 2. The two modes — choose before you start

| Question | Mode A · Real DR Drill | Mode B · Non-Destructive Test |
|---|---|---|
| What are you proving? | End-to-end failover + failback + Client Redirect + DNS cutover | Data parity, object presence, RBAC on DR |
| Is `HELIOS_ANALYTICS_PROD` on production made read-only? | **Yes** (briefly) | **No** |
| Are other tenants affected? | Account-level admin ops blocked briefly; data untouched | **No** |
| Manual DNS / OCSP flip exercised? | **Yes** | No (clone reached via direct DR URL) |
| Time required | Hours | ~30–60 min |
| Risk to production | Higher | **Lower** |
| Recommended first | After Mode B passes + connection-URL migration done | **Yes — run Mode B first** |

---

## 3. Pre-flight checklist

### 3.1 T-14 days

| Item | Owner | Status |
|---|---|---|
| Confirm account is Business Critical | TBD | ☐ |
| Confirm failover groups exist with correct membership | TBD | ☐ |
| Confirm `HELIOS_CONN` Connection object exists; finalize name | TBD | ☐ |
| **Migrate all `HELIOS_ANALYTICS_PROD` writers/readers to the connection URL** | TBD | ☐ |
| Complete object audit (§1.3); resolve append-only streams + dangling references | TBD | ☐ |
| Grant DR service identity IAM access on shared S3 buckets | TBD | ☐ |
| Build DR-side SNS topic + SQS queue + notification integration for pipes | TBD | ☐ |
| Resolve every inbound data share (auto-fulfillment or dual share) | TBD | ☐ |
| Pre-create VPC endpoints; pre-stage Route 53 records (connection + OCSP); set TTL 60–300s | Network team | ☐ |

### 3.2 T-1 day

| Item | Owner | Status |
|---|---|---|
| Confirm replication lag < refresh interval (run §3.4) | TBD | ☐ |
| Engage Snowflake support for the window | TBD | ☐ |
| Dry-run the §5/§6 commands or read aloud as a team | TBD | ☐ |
| Confirm network team on the bridge for the DNS step (Mode A) | Network team | ☐ |

### 3.3 T-1 hour

| Item | Owner | Status |
|---|---|---|
| Run baseline snapshot (§7) on production and save output | TBD | ☐ |
| Confirm the latest refresh just completed (minimal lag) | TBD | ☐ |
| Confirm DR reachable via direct DR URL | TBD | ☐ |

### 3.4 Pre-flight validation SQL (run on production / primary)

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §3.4 PRE-FLIGHT — MERIDIAN_PROD (us-east-1)
-- ═══════════════════════════════════════════════════════════════════════════
USE ROLE ACCOUNTADMIN;

-- 1. Failover/replication groups and state
SHOW FAILOVER GROUPS;
SHOW REPLICATION GROUPS;

-- 2. Replication lag for the workload group
SELECT name, last_refresh_status, last_refresh_start_time, last_refresh_end_time,
       DATEDIFF('second', last_refresh_end_time, CURRENT_TIMESTAMP()) AS seconds_since_last_refresh
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('FG_HELIOS_DB'))
ORDER BY last_refresh_end_time DESC LIMIT 5;

-- 3. Member databases of each group
SHOW DATABASES IN FAILOVER GROUP FG_HELIOS_DB;
SHOW DATABASES IN FAILOVER GROUP FG_NON_HELIOS_DBS;

-- 4. CANONICAL DEPENDENCY CHECK — anything that would block refresh/failover.
--    Resolve every row with IS_BLOCKING_REFRESH = TRUE before proceeding.
SELECT * FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_DANGLING_REFERENCES('FG_HELIOS_DB'));

-- 5. Connection object + its primary side
SHOW CONNECTIONS;

-- 6. Non-replicable / blocking object classes in HELIOS_ANALYTICS_PROD
SHOW STREAMS IN DATABASE HELIOS_ANALYTICS_PROD;          -- inspect MODE for APPEND_ONLY (must be zero)
SHOW EXTERNAL TABLES IN DATABASE HELIOS_ANALYTICS_PROD;
SELECT 'HYBRID TABLES' AS object_class, COUNT(*) AS cnt
FROM HELIOS_ANALYTICS_PROD.INFORMATION_SCHEMA.TABLES WHERE IS_HYBRID = 'YES';

-- 7. Inbound shares feeding the workload (cannot replicate — see §8)
SHOW SHARES;   -- inspect kind = INBOUND

-- 8. Replication usage (cost/volume sanity check)
SELECT start_time, end_time, database_name, bytes_transferred, credits_used
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_USAGE_HISTORY(
    DATE_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP())))
ORDER BY start_time DESC;
```

---

## 4. Mode B — Non-Destructive Test (Clone-and-Test, recommended first)

> **Use this when** you want to validate data, objects, and RBAC on DR **without** demoting production, reversing replication, or touching other tenants.

Instead of promoting `FG_HELIOS_DB`, **clone** the replicated `HELIOS_ANALYTICS_PROD` on DR into a throwaway database and validate against the clone. Production stays primary throughout.

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §4 MODE B — CLONE-AND-TEST (Execute on the DR account, us-west-2)
-- ═══════════════════════════════════════════════════════════════════════════
USE ROLE ACCOUNTADMIN;

-- 1. Verify DR is a healthy secondary
SHOW REPLICATION DATABASES;
SELECT name, last_refresh_status, last_refresh_end_time
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('FG_HELIOS_DB'))
ORDER BY last_refresh_end_time DESC LIMIT 3;
-- Expected: last_refresh_status = SUCCEEDED on the configured cadence.

-- 2. Zero-copy clone the replicated DB into a test-only database (instant, fully writable)
CREATE DATABASE HELIOS_ANALYTICS_PROD_DRTEST CLONE HELIOS_ANALYTICS_PROD;

-- 3. (Optional) Re-create non-replicated objects on the clone from IaC for end-to-end testing
--    (external/hybrid/event tables, pipes). Inbound-share deps can't be cloned — validate via §8.

-- 4. Grant a test-runner role access to the clone
GRANT USAGE ON DATABASE HELIOS_ANALYTICS_PROD_DRTEST TO ROLE HELIOS_DR_TEST_RUNNER;
GRANT USAGE ON ALL SCHEMAS IN DATABASE HELIOS_ANALYTICS_PROD_DRTEST TO ROLE HELIOS_DR_TEST_RUNNER;
GRANT SELECT ON ALL TABLES IN DATABASE HELIOS_ANALYTICS_PROD_DRTEST TO ROLE HELIOS_DR_TEST_RUNNER;
GRANT SELECT ON FUTURE TABLES IN DATABASE HELIOS_ANALYTICS_PROD_DRTEST TO ROLE HELIOS_DR_TEST_RUNNER;

-- 5. Run the test plan against the clone (§9). Reads/writes on the clone don't affect the replica.

-- 6. Validate external-stage reachability (proves the DR IAM trust policy works)
LIST @HELIOS_ANALYTICS_PROD_DRTEST.RAW.S3_INBOUND_STAGE;
-- "access denied" => DR IAM role is missing trust/access on the bucket (best-practices §4.1).

-- 7. Drop the test database when complete
DROP DATABASE HELIOS_ANALYTICS_PROD_DRTEST;

-- 8. Defensive verification — production should still be primary throughout
SHOW FAILOVER GROUPS;   -- FG_HELIOS_DB primary should still be MERIDIAN_PROD
```

> **Why this is safe.** Production is never demoted, the connection is never flipped, DNS is untouched, and other tenants never notice. Blast radius is the throwaway clone.

---

## 5. Mode A — Failover (Production → DR)

> **Use this when** rehearsing (or responding to) a real regional outage. Promotes `FG_ACCOUNT_LEVEL` + `FG_HELIOS_DB` to us-west-2. **`FG_NON_HELIOS_DBS` is intentionally NOT promoted.**

### 5.1 Failover steps

| Step | Description | Action | Est. time | Status |
|---|---|---|---|---|
| 5.1.1 | **Declare** | Authorize the Helios failover | 1–5 min | ☐ |
| 5.1.2 | Stop Helios writes on production (if reachable) | Pause ETL/pipes/apps | 1–2 min | ☐ |
| 5.1.3 | Final refresh (if production reachable) | `ALTER FAILOVER GROUP ... REFRESH` | 1–3 min | ☐ |
| 5.1.4 | Promote account-level group on DR | `ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL PRIMARY` | 1–2 min | ☐ |
| 5.1.5 | Promote workload DB group on DR | `ALTER FAILOVER GROUP FG_HELIOS_DB PRIMARY` | 1–2 min | ☐ |
| 5.1.6 | Promote the Connection on DR | `ALTER CONNECTION HELIOS_CONN PRIMARY` | < 1 min | ☐ |
| 5.1.7 | **Manual DNS flip (PrivateLink)** | Repoint **connection URL + OCSP URL** A records to `vpce-helios-usw2` | 2–5 min | ☐ |
| 5.1.8 | Wait for DNS TTL | 60–300 s | 1–5 min | ☐ |
| 5.1.9 | Resume Helios tasks on DR | `ALTER TASK ... RESUME` (if not auto) | 1–2 min | ☐ |
| 5.1.10 | Validate external stages on DR | `LIST @stage` | 2–5 min | ☐ |
| 5.1.11 | Validate app connectivity via connection URL | Smoke test | 5–10 min | ☐ |
| 5.1.12 | Confirm non-Helios DBs still read-write on production | `SHOW DATABASES` on production | 1–2 min | ☐ |
| 5.1.13 | Notify stakeholders | — | 1–2 min | ☐ |

### 5.2 Failover SQL

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §5.2 MODE A — FAILOVER (Execute on the DR account, us-west-2)
-- ═══════════════════════════════════════════════════════════════════════════
USE ROLE ACCOUNTADMIN;

-- 1. Optional final refresh (only if production is still reachable)
ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL REFRESH;
ALTER FAILOVER GROUP FG_HELIOS_DB REFRESH;

-- 2. Promote the account-level group FIRST (roles/warehouses the workload depends on)
ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL PRIMARY;

-- 3. Promote the workload database group
ALTER FAILOVER GROUP FG_HELIOS_DB PRIMARY;

-- 4. Promote the Connection so the connection URL resolves to DR
ALTER CONNECTION HELIOS_CONN PRIMARY;

-- 5. Verify promotion
SHOW FAILOVER GROUPS;   -- FG_ACCOUNT_LEVEL + FG_HELIOS_DB primary = MERIDIAN_DR
SHOW CONNECTIONS;       -- HELIOS_CONN is_primary = true on DR

-- 6. DO NOT promote FG_NON_HELIOS_DBS — those databases stay primary on production.

-- 7. Resume workload tasks if suspended on DR
SHOW TASKS IN DATABASE HELIOS_ANALYTICS_PROD;
-- ALTER TASK HELIOS_ANALYTICS_PROD.MART.T_REFRESH_SETTLEMENT RESUME;   -- as needed

-- 8. Validate an external stage (confirms DR IAM access on S3)
-- LIST @HELIOS_ANALYTICS_PROD.RAW.S3_INBOUND_STAGE;
```

```text
-- ─────────────────────────────────────────────────────────────────────────────
-- §5.1.7  MANUAL DNS FLIP (AWS PrivateLink) — network team
-- ─────────────────────────────────────────────────────────────────────────────
-- Repoint BOTH the connection URL and the OCSP URL from the production endpoint to DR:
--   meridian-helios_conn.privatelink.snowflakecomputing.com  ->  vpce-helios-usw2  (was vpce-helios-use1)
--   ocsp.<...>.privatelink.snowflakecomputing.com             ->  vpce-helios-usw2
-- TTL must already be 60–300s. Flipping only the connection URL (not OCSP) => TLS failures.
```

---

## 6. Mode A — Failback (DR → Production)

Once us-east-1 / the production account is healthy, fail back.

| Step | Description | Action | Est. time | Status |
|---|---|---|---|---|
| 6.1 | Confirm production restored | Health check | 5–10 min | ☐ |
| 6.2 | Refresh production from DR | `ALTER FAILOVER GROUP ... REFRESH` on production | 10–30 min | ☐ |
| 6.3 | Stop Helios writes on DR | Pause ETL/pipes/apps | 1–2 min | ☐ |
| 6.4 | Final refresh to production | `ALTER FAILOVER GROUP ... REFRESH` | 1–3 min | ☐ |
| 6.5 | Promote account-level group on production | `ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL PRIMARY` | 1–2 min | ☐ |
| 6.6 | Promote workload DB group on production | `ALTER FAILOVER GROUP FG_HELIOS_DB PRIMARY` | 1–2 min | ☐ |
| 6.7 | Promote Connection on production | `ALTER CONNECTION HELIOS_CONN PRIMARY` | < 1 min | ☐ |
| 6.8 | **Reverse the DNS flip** | Repoint connection URL + OCSP back to `vpce-helios-use1` | 2–5 min | ☐ |
| 6.9 | Wait for DNS TTL | 60–300 s | 1–5 min | ☐ |
| 6.10 | Resume Helios tasks on production | `ALTER TASK ... RESUME` | 1–2 min | ☐ |
| 6.11 | Validate connectivity via connection URL | Smoke test | 5–10 min | ☐ |
| 6.12 | Notify stakeholders | — | 1–2 min | ☐ |

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §6 MODE A — FAILBACK (Execute on the production account, us-east-1)
-- ═══════════════════════════════════════════════════════════════════════════
USE ROLE ACCOUNTADMIN;
ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL REFRESH;
ALTER FAILOVER GROUP FG_HELIOS_DB REFRESH;
ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL PRIMARY;
ALTER FAILOVER GROUP FG_HELIOS_DB PRIMARY;
ALTER CONNECTION HELIOS_CONN PRIMARY;
SHOW FAILOVER GROUPS;   -- primary = MERIDIAN_PROD
SHOW CONNECTIONS;       -- HELIOS_CONN is_primary = true on production
-- Then reverse the manual DNS flip (network team): connection URL + OCSP URL -> vpce-helios-use1
```

---

## 7. Baseline / post-test snapshot (run on production before AND after)

Run before the drill and again after; diff the outputs — they should be identical, proving the drill left production (and the non-Helios tenants) unchanged.

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §7 BASELINE / POST-TEST SNAPSHOT — run on production (us-east-1)
-- ═══════════════════════════════════════════════════════════════════════════
USE ROLE ACCOUNTADMIN;

-- 1. Workload object counts
SELECT TABLE_SCHEMA, COUNT(*) AS table_count, SUM(ROW_COUNT) AS rows, SUM(BYTES) AS bytes
FROM HELIOS_ANALYTICS_PROD.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
GROUP BY 1 ORDER BY 1;

-- 2. Failover group state
SHOW FAILOVER GROUPS;
SELECT name, last_refresh_status, last_refresh_end_time,
       DATEDIFF('second', last_refresh_end_time, CURRENT_TIMESTAMP()) AS seconds_ago
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('FG_HELIOS_DB'))
ORDER BY last_refresh_end_time DESC LIMIT 3;

-- 3. Connection state
SHOW CONNECTIONS;

-- 4. Account-level object counts (covered by FG_ACCOUNT_LEVEL)
SELECT COUNT(*) AS roles FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES WHERE DELETED_ON IS NULL;
SELECT COUNT(*) AS users FROM SNOWFLAKE.ACCOUNT_USAGE.USERS WHERE DELETED_ON IS NULL;
SHOW WAREHOUSES;

-- 5. Non-Helios databases must be unchanged and primary on production
SHOW DATABASES IN FAILOVER GROUP FG_NON_HELIOS_DBS;

-- 6. Non-replicable object counts (should be identical pre/post)
SHOW STREAMS IN DATABASE HELIOS_ANALYTICS_PROD;        -- check no new APPEND_ONLY
SHOW EXTERNAL TABLES IN DATABASE HELIOS_ANALYTICS_PROD;

-- 7. Replication usage — watch for an unexpected spike
SELECT start_time, end_time, database_name, bytes_transferred, credits_used
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_USAGE_HISTORY(
    DATE_RANGE_START => DATEADD('hour', -3, CURRENT_TIMESTAMP())))
ORDER BY start_time DESC;
```

---

## 8. Inbound data shares — pre-test resolution (critical)

Inbound-share databases **cannot be replicated**. For each share feeding `HELIOS_ANALYTICS_PROD`, resolve **before** the drill:

| Provider / Share | Workload dependency | Resolution | DR-side present? | Status |
|---|---|---|---|---|
| `MARKETDATA_VENDOR.PRICES_SHARE` | `MART.FACT_POSITION_PNL` joins to live prices | Auto-Fulfillment / Dual-share | ☐ | ☐ |
| `RATINGS_VENDOR.CREDIT_SHARE` | `REF.ISSUER_RATINGS` | Auto-Fulfillment / Dual-share | ☐ | ☐ |

**Options:** (1) **Auto-Fulfillment** — provider auto-fulfills into us-west-2; (2) **Dual share** — provider shares to both `MERIDIAN_PROD` and `MERIDIAN_DR`.

```sql
-- On the DR account
SHOW SHARES;     -- confirm each required inbound share appears (kind = INBOUND)
-- SELECT COUNT(*) FROM MARKETDATA_PRICES.PUBLIC.LIVE_PRICES;   -- confirm queryable
```

> Until every inbound share is independently available on DR, logic that joins shared data returns wrong/empty results after failover even though the failover "succeeds."

---

## 9. Test plan (run against the clone in Mode B, or DR in Mode A)

| # | Test | Method | Pass criteria |
|---|---|---|---|
| 9.1 | Data parity — row counts (**Tier 1 first**, §1.4.4) | `COUNT(*)` on Tier 1 tables (settlement/position marts) vs production | Match (modulo continuous-ingest delta) |
| 9.2 | Data parity — checksums (**Tier 1**) | `HASH_AGG(*)` on a deterministic projection | Hash matches |
| 9.3 | Dynamic tables | Confirm reinitialize + refresh on DR | First refresh completes |
| 9.4 | External stages | `LIST @RAW.S3_INBOUND_STAGE` + read a file | Files reachable (IAM trust works) |
| 9.5 | Pipes / Snowpipe | Drop a test file in the DR S3 bucket | Auto-ingest fires (SNS/SQS + notification integration configured) |
| 9.6 | Standard streams | Verify stream offsets on DR | Streams usable |
| 9.7 | Tasks | Confirm in-scope tasks schedule on DR | Triggerable; owning roles present |
| 9.8 | RBAC fidelity | Log in as several roles; check visibility + masking | Identical to production |
| 9.9 | Inbound shares | Query shared market/ratings data on DR | Returns expected rows (§8) |
| 9.10 | Connection URL (Mode A) | Connect an app via `MERIDIAN-HELIOS_CONN...` | Resolves to DR after DNS flip |
| 9.11 | OCSP / TLS (Mode A) | Establish TLS via PrivateLink to DR | No cert validation failure |
| 9.12 | Cost | Inspect replication credits for the window | Within forecast |

---

## 10. Roles & responsibilities

| Role | Responsibility |
|---|---|
| DR Test Lead | Owns the test plan + go/no-go decision |
| Snowflake Admin (ACCOUNTADMIN) | Executes failover-group + connection SQL |
| AWS Network Team | Pre-stages VPC endpoints/Route 53; performs + times the manual DNS + OCSP flip |
| AWS IAM Admin | Grants DR service identity access on the S3 buckets |
| Helios Data Engineering | Migrates pipelines to the connection URL; validates pipes/streams/tasks |
| Provider Liaison | Drives inbound-share auto-fulfillment / dual-share per provider |
| Snowflake Support | On-call during the window |

---

## 11. Known constraints & watch-outs

| # | Item | Detail |
|---|---|---|
| 11.1 | PrivateLink breaks auto-redirect | Every failover needs a **manual DNS change** — dominant RTO component. |
| 11.2 | OCSP URL must also be flipped | Flipping only the connection URL causes TLS validation failures. |
| 11.3 | DNS TTL lowered in advance | Set 60–300s before any drill; can't help retroactively. |
| 11.4 | Append-only streams block refresh | Must be zero in `HELIOS_ANALYTICS_PROD` before the group is created. |
| 11.5 | External / hybrid / event tables don't replicate | External tables skipped **silently**. Map dependencies. |
| 11.6 | Internal-stage files >5 GB fail refresh | Audit stage file sizes; enable directory tables if files must replicate. |
| 11.7 | DR service identity RBAC | Storage integration replicates, but the DR IAM role needs its own trust/access grant. |
| 11.8 | Pipe event plumbing not replicated | SNS topic + SQS queue + notification integration must be built on DR. |
| 11.9 | Inbound shares not replicable | Auto-fulfillment or dual share required per provider (§8). |
| 11.10 | Don't promote `FG_NON_HELIOS_DBS` | Keeps non-Helios tenants read-write — the core design goal. |
| 11.11 | Use SQL, not the GUI | The Snowsight failover-group editor can silently reset the refresh interval. |
| 11.12 | Check dangling references | `REPLICATION_GROUP_DANGLING_REFERENCES()` — resolve `IS_BLOCKING_REFRESH = TRUE` before refresh. |

---

## 12. Open items tracker

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | Confirm Business Critical edition | TBD | ☐ |
| 2 | Finalize Connection object name (`HELIOS_CONN`?) | TBD | ☐ |
| 3 | Complete object audit; resolve append-only streams + dangling refs | TBD | ☐ |
| 4 | Resolve all inbound shares | TBD | ☐ |
| 5 | Migrate all Helios writers/readers to the connection URL | TBD | ☐ |
| 6 | Grant DR service identity IAM access on shared S3 buckets | TBD | ☐ |
| 7 | Build DR-side SNS/SQS + notification integration | TBD | ☐ |
| 8 | Pre-stage VPC endpoints + Route 53 (connection + OCSP); set TTL | Network team | ☐ |
| 9 | Run Mode B clone-and-test drill | TBD | ☐ |
| 10 | Schedule Mode A end-to-end drill (low-traffic window) | TBD | ☐ |

---

*Worked example derived from the generic Snowflake BCDR best-practice set. Fictional customer; living document — revise after each drill.*
