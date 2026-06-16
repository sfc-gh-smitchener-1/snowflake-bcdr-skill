# Plymouth Rock Snowflake DR Failover / Failback Runbook
### Business Critical Edition · AWS us-east-1 (Northern Virginia) ⇄ us-east-2 (Ohio)
### Two Modes: Mode A — Real DR Drill (destructive) · Mode B — Non-Destructive Test (Plymouth's May 2026 scope)

> **Status.** Living document. Based on the May 14, 2026 working session with Plymouth. Authored by Snowflake Team (Steve Mitchener). Adapts the canonical Snowflake BCDR runbook to Plymouth's Business Critical / AWS environment and Plymouth's non-destructive test requirement.
>
> **Audience.** Plymouth operations team: Musawar Nadeem (Test Lead), Pulugundla Narasimham (Test Engineer), Rajan Rajanagan (Architecture/Approvals), Robert Gay (Tableau/consumers), Jill Weigand (Operations/Backups), Paul Lobello (Performance sign-off). Snowflake side: Steve Mitchener (Snowflake), Tom Smith (Snowflake Product).
>
> **Companion documents.** `PlymouthRock-DR-Summary.md` · `PlymouthRock-DR-Best-Practices.md`

---

## 0. Why this document exists

Plymouth Rock is preparing to **retire its legacy data warehouse**. Before that gate event, Plymouth wants to execute a **Snowflake DR test** that:

1. Validates the failover-group + client-redirect plumbing between NoVA (us-east-1) and Ohio (us-east-2).
2. Confirms behavior of non-replicated objects (hybrid tables, time travel, fail-safe, Streamlit apps).
3. **Does NOT change Virginia's production state.** Any data, schema, or grant change made on Ohio during the test must be discarded; Virginia must return to primary state "as if nothing happened."

That last requirement is the unusual one. The canonical Snowflake failover/failback pattern reverses replication direction on failback (Ohio becomes new primary; Virginia refreshes from Ohio). Plymouth wants the opposite: break replication direction so Virginia is never overwritten by Ohio, then re-seed Ohio cleanly from Virginia after the test. This runbook documents both modes so Plymouth can use the right one now and have the real-DR runbook ready later.

---

## 1. Plymouth Environment Reference

### 1.1 Topology

Production: AWS us-east-1 (Northern Virginia) — PLYMOUTH_PROD account
- Databases: PLYMOUTH_PROD, PLYMOUTH_ANALYTICS (+ others TBD)
- Ingest: HVR (writing from Northern Virginia into Snowflake)
- BI: Tableau (Robert Gay) + other consumers
- Schedulers: Snowflake Tasks + external schedulers

DR: AWS us-east-2 (Ohio) — PLYMOUTH_PROD_DR account (locator TBD)
- Read-only secondary during normal operations
- Becomes primary during Mode A failover

Connectivity: Connection URL `snowflake.plymouth.<your-domain>` → *(confirm: public org URL or PrivateLink)*

### 1.2 Account inventory (Plymouth to confirm placeholder values)

| Component | Plymouth value | Source |
|---|---|---|
| Edition | **Business Critical** (converted from Enterprise) | Meeting 29:08 — Musawar |
| Cloud | **AWS** | Meeting 47:01 — Snowflake Team |
| Primary region | **us-east-1 (Northern Virginia)** | Meeting 0:17 — Musawar |
| DR region | **us-east-2 (Ohio)** | Meeting 0:17 — Musawar |
| Org | `<PLYMOUTH_ORG>` *(fill in)* | Open Item 1 |
| Account locator — Primary | `<PLYMOUTH_PROD>` *(Pulugundla to fill)* | Open Item 1 |
| Account locator — DR | `<PLYMOUTH_PROD_DR>` *(Pulugundla to fill)* | Open Item 1 |
| Primary databases | `PLYMOUTH_PROD`, `PLYMOUTH_ANALYTICS` | Runbook SQL |
| Connection object | `PLYMOUTH_CONN` *(confirm exact name)* | Open Item 2 |
| Connection URL | `snowflake.plymouth.<your-domain>` *(confirm)* | Meeting 27:43 — Musawar |
| Connectivity type | `<confirm: public org URL or PrivateLink>` | Open Item 2 |
| Failover group refresh interval | **5 MINUTE** (set via SQL — GUI shows 10 min, bug) | Meeting 35:03 — Pulugundla |
| Primary ingest | **HVR** (writing from NoVA into Snowflake) | Meeting 50:26 — Musawar |
| BI consumers | **Tableau** (Robert Gay) + others | Meeting implied |
| Schedulers | Snowflake Tasks + external schedulers | Meeting 27:24 |
| Time travel max retention | Up to **15 days** on some tables | Meeting 15:08 — Pulugundla |
| RPO target | **5 minutes** | BC/DR v1 doc |
| RTO target | **15 minutes** | BC/DR v1 doc |

### 1.3 What is and is not replicated

| Object class | Replicates? | Plymouth-specific note |
|---|---|---|
| Permanent & transient tables | ✅ | Standard |
| Dynamic tables | ✅ | First refresh on Ohio is full reinitialization |
| External stages | ✅ (definition) | Ohio IAM trust must be pre-configured on S3 buckets |
| Internal stages | ✅ (caveats) | No file >5 GB; directory table enabled to replicate files |
| Storage integrations | ✅ (object) | Ohio DR account has a **different IAM ARN** — add trust policy to S3 buckets |
| Pipes / Snowpipe | ✅ (object) | Plymouth uses HVR — confirm whether any Snowpipe objects exist |
| Streams (standard) | ✅ | Source must be in same group / database |
| **Streams (append-only)** | ❌ | **Must be zero in PLYMOUTH_PROD / PLYMOUTH_ANALYTICS — blocks refresh** |
| Tasks | ✅ | Must have run once; owning roles in `FG_ACCOUNT_LEVEL` |
| External tables | ❌ | **Skipped silently** — map all downstream dependencies |
| **Hybrid tables** | ❌ | **Plymouth has hybrid tables (confirmed).** Remain on NoVA; NOT on Ohio; NOT dropped from NoVA |
| Event tables | ❌ | DMF history won't exist on Ohio |
| Inbound datashare databases | ❌ | Audit required — auto-fulfillment or dual share per provider |
| Masking / row-access policies | ✅ | — |
| Tags | ✅ | Cannot be modified on Ohio side |
| Stored procedures & UDFs | ✅ | Replicate external-network-access integrations too |
| Users / roles / warehouses / monitors / policies / integrations | ✅ (BC) | Covered by `FG_ACCOUNT_LEVEL` |
| **Streamlit apps** | ✅ (BCR-2316) | See §11.2 — account-level dependencies must be verified on Ohio |
| **Time travel history** | ❌ | *Setting* replicates; *historical records* do not. Ohio time travel starts fresh from failover moment. NoVA history is preserved (NoVA becomes read-only secondary). |
| **Fail-safe data** | ❌ | Same as time travel — setting replicates, accumulated data does not. |

### 1.4 BCDR analytics: feeding the 5-minute RPO / 15-minute RTO

Run on PLYMOUTH_PROD and PLYMOUTH_ANALYTICS during planning. Re-run before each drill.

#### 1.4.1 Per-table churn — primary RPO/RTO driver

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §1.4.1  Hottest tables — PLYMOUTH_PROD (run also for PLYMOUTH_ANALYTICS)
-- Churn % = failsafe / active * 100. High churn = high RPO exposure + high RTO cost.
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
WHERE TABLE_CATALOG = 'PLYMOUTH_PROD'
  AND DELETED = FALSE
ORDER BY FAILSAFE_BYTES DESC
LIMIT 50;
```

#### 1.4.2 Database-wide churn ratio — RTO indicator

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §1.4.2  Workload volatility for PLYMOUTH_PROD as a whole.
-- ═══════════════════════════════════════════════════════════════════════════
SELECT
    DATABASE_NAME,
    AVG(AVERAGE_DATABASE_BYTES) / POWER(1024,3) AS AVG_DB_GB,
    AVG(AVERAGE_FAILSAFE_BYTES) / POWER(1024,3) AS AVG_FAILSAFE_GB,
    ROUND(AVG(AVERAGE_FAILSAFE_BYTES) / NULLIF(AVG(AVERAGE_DATABASE_BYTES),0) * 100, 1) AS CHURN_RATIO_PCT
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
WHERE DATABASE_NAME IN ('PLYMOUTH_PROD', 'PLYMOUTH_ANALYTICS')
  AND USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())
GROUP BY DATABASE_NAME;
```

#### 1.4.3 Replication volume & cost — is 5-minute RPO feasible?

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §1.4.3  Replication cost / volume for PLYMOUTH_PROD + PLYMOUTH_ANALYTICS
-- ═══════════════════════════════════════════════════════════════════════════
SHOW FAILOVER GROUPS;  -- inspect REPLICATION_SCHEDULE — must show '5 MINUTE' not '10 MINUTE'

SELECT
    DATABASE_NAME,
    SUM(CREDITS_USED)          AS TOTAL_REPLICATION_CREDITS,
    SUM(BYTES_TRANSFERRED)     AS TOTAL_BYTES_REPLICATED,
    COUNT(DISTINCT START_TIME) AS REPLICATION_EVENTS
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_REPLICATION_USAGE_HISTORY
WHERE DATABASE_NAME IN ('PLYMOUTH_PROD', 'PLYMOUTH_ANALYTICS')
  AND START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY DATABASE_NAME;
```

#### 1.4.4 DR tiers

| Tier | Defined as | Treatment |
|---|---|---|
| **Tier 1 — Critical** | Highest churn + feeds downstream tasks / semantic views | Drives 5-min RPO; row-count + checksum parity verified first after every refresh |
| **Tier 2 — Important** | Hot but no critical downstream | Verified in post-failover validation; churn monitored for cost |
| **Tier 3 — Standard** | Cold / low churn / static | Replicates with group; spot-check only |
| **⚠ At-risk** | `IS_TRANSIENT = TRUE`, or behind a gap (hybrid tables, append-only streams, inbound shares) | Highest RPO risk — resolve before first drill |

---

## 2. The two modes — choose before you start

Plymouth must make this decision **before** the test window opens.

| Question | Mode A · Real DR Drill | Mode B · Non-Destructive Test |
|---|---|---|
| What are you proving? | End-to-end failover + failback + full HVR write redirect | DR mechanism works; non-replicated objects behave; Client Redirect routes correctly |
| Are HVR writes redirected to Ohio? | **Yes** — that's the whole point | **Yes** — HVR can write to Ohio clone during test |
| Does failback overwrite Virginia? | Yes (forward-then-reverse replication) | **No** — Virginia is never modified |
| Time required | Hours | **~30–60 min** active work + validation |
| Risk to production | Higher (real cutover, real load) | **Lower** (Virginia untouched) |
| DNS/OCSP flip required? | **Yes** (if PrivateLink) | No (clone reached via direct Ohio URL) |
| Recommended for pre-DW-retirement gate | Reserve for after DW retirement | **Yes — Plymouth's May 2026 test** |

**Plymouth's May 2026 test: Mode B.** Mode A should be scheduled as a separate exercise *after* the legacy DW is retired and HVR is the sole source of truth, so a real production cutover can be rehearsed safely.

---

## 3. Pre-flight checklist

### 3.1 T-7 days

| Item | Owner | Status |
|---|---|---|
| Confirm Mode B and circulate to all stakeholders | Musawar | ☐ |
| Lock test window (recommend Saturday or Sunday) | Rajan | ☐ |
| Open proactive Snowflake support case — provide account, region, expected window; request AAA Ninja assignment | Snowflake Team (Steve) | ☐ |
| Inventory all databases in scope; confirm each is in the failover group | Pulugundla | ☐ |
| Inventory all Snowflake Tasks; record current state (resumed/suspended) and schedule | Pulugundla | ☐ |
| Inventory non-replicated objects (hybrid tables, Streamlit apps, external tables, internal stages) | Pulugundla + Robert | ☐ |
| **Confirm HVR's connection target is the Connection URL** (not the raw NoVA account URL) | Musawar | ☐ |
| **Confirm Tableau and all other BI/ETL consumers are on the Connection URL** | Robert Gay | ☐ |
| Communicate scheduled test to downstream consumers (Tableau users, apps) | Rajan | ☐ |
| Run BCDR analytics (§1.4); confirm 5-min RPO is achievable | Pulugundla + Snowflake Team | ☐ |
| Verify BCR-2316 bundle status; complete Streamlit dependency map (§11.2) | Pulugundla + Snowflake Team | ☐ |

### 3.2 T-1 day

| Item | Owner | Status |
|---|---|---|
| Confirm replication lag < 5 minutes — run §3.4 SQL | Pulugundla | ☐ |
| Confirm Snowflake support case has a named engineer assigned | Snowflake Team | ☐ |
| Final dry-run of the §4 commands (read aloud as a team) | Musawar | ☐ |
| Pause HVR jobs (Mode B — confirm with HVR team) | Musawar | ☐ |
| Confirm in-scope Snowflake Tasks are in expected state | Pulugundla | ☐ |

### 3.3 T-1 hour

| Item | Owner | Status |
|---|---|---|
| Open Snowflake support bridge | AAA Ninja / Support | ☐ |
| All test runners on shared video bridge | Rajan | ☐ |
| Run **baseline snapshot** (§7) on Virginia and save output | Pulugundla | ☐ |
| Confirm the failover group refresh just completed (minimal lag) | Pulugundla | ☐ |
| Confirm Ohio is reachable via direct Ohio URL | Robert Gay | ☐ |

### 3.4 Pre-flight validation SQL (run on NoVA primary)

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §3.4 PRE-FLIGHT — NoVA Primary (PLYMOUTH_PROD account)
-- ═══════════════════════════════════════════════════════════════════════════
USE ROLE ACCOUNTADMIN;

-- 1. Failover / replication group state and schedule
SHOW FAILOVER GROUPS;
SHOW REPLICATION GROUPS;
-- Verify: REPLICATION_SCHEDULE = '5 MINUTE' for FG_PLYMOUTH_DB (GUI may show 10 — use SQL)

-- 2. Replication lag for PLYMOUTH_PROD
SELECT name, last_refresh_status, last_refresh_start_time, last_refresh_end_time,
       DATEDIFF('second', last_refresh_end_time, CURRENT_TIMESTAMP()) AS seconds_since_last_refresh
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('FG_PLYMOUTH_DB'))
ORDER BY last_refresh_end_time DESC LIMIT 5;

-- 3. Member databases
SHOW DATABASES IN FAILOVER GROUP FG_PLYMOUTH_DB;
SHOW DATABASES IN FAILOVER GROUP FG_NON_PLYMOUTH_DBS;  -- if this group exists

-- 4. Blocking dangling references — resolve every IS_BLOCKING_REFRESH = TRUE row before proceeding
SELECT * FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_DANGLING_REFERENCES('FG_PLYMOUTH_DB'));

-- 5. Connection object
SHOW CONNECTIONS;
-- Verify PLYMOUTH_CONN is_primary = true on NoVA

-- 6. Non-replicable objects (MUST be zero append-only streams)
SHOW STREAMS IN DATABASE PLYMOUTH_PROD;       -- inspect MODE: must not be APPEND_ONLY
SHOW STREAMS IN DATABASE PLYMOUTH_ANALYTICS;
SHOW EXTERNAL TABLES IN DATABASE PLYMOUTH_PROD;
SELECT 'HYBRID TABLES' AS object_class, COUNT(*) AS cnt
FROM PLYMOUTH_PROD.INFORMATION_SCHEMA.TABLES WHERE IS_HYBRID = 'YES';

-- 7. Inbound shares feeding Plymouth workload
SHOW SHARES;  -- inspect kind = INBOUND

-- 8. Snowpipe objects (Plymouth uses HVR; confirm if any Snowpipe objects also exist)
SHOW PIPES IN DATABASE PLYMOUTH_PROD;
SHOW PIPES IN DATABASE PLYMOUTH_ANALYTICS;

-- 9. Replication cost / volume baseline (last 24h)
SELECT start_time, end_time, database_name, bytes_transferred, credits_used
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_USAGE_HISTORY(
    DATE_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP())))
ORDER BY start_time DESC;
```

---

## 4. Mode B — Non-Destructive Test (Plymouth's May 2026 scope)

> **Use this when** Plymouth wants to validate DR without demoting production, reversing replication, or touching HVR/Tableau. Virginia stays primary throughout. All test operations are against the Ohio clones.

The test proceeds in two phases: **pause and sync**, then **clone and validate** on Ohio.

### 4.1 Mode B steps

| Step | Description | Action | Status |
|---|---|---|---|
| 4.1.1 | **Pause HVR** | Stop HVR ingest jobs | ☐ |
| 4.1.2 | **Final refresh** | Force a sync to minimize RPO gap | `ALTER FAILOVER GROUP FG_PLYMOUTH_DB REFRESH` (run on Ohio) | ☐ |
| 4.1.3 | **Verify Ohio secondary** | Confirm refresh succeeded | See §4.2 SQL step 1 | ☐ |
| 4.1.4 | **Clone PLYMOUTH_PROD on Ohio** | Zero-copy clone; instantly writable | `CREATE DATABASE PLYMOUTH_PROD_TEST CLONE PLYMOUTH_PROD` (run on Ohio) | ☐ |
| 4.1.5 | **Clone PLYMOUTH_ANALYTICS on Ohio** | Zero-copy clone | `CREATE DATABASE PLYMOUTH_ANALYTICS_TEST CLONE PLYMOUTH_ANALYTICS` (run on Ohio) | ☐ |
| 4.1.6 | **Grant test-runner role on clones** | Tailor to Plymouth's RBAC | See §4.2 SQL step 4 | ☐ |
| 4.1.7 | **Run Plymouth's test plan** | Queries, INSERTs, UPDATEs against clones only | See §9 | ☐ |
| 4.1.8 | **Validate Streamlit apps** (BCR-2316) | Smoke-test each SiS app in the Ohio clone | See §11.2.4 | ☐ |
| 4.1.9 | **Capture post-test snapshot on Ohio** | Diff against pre-test baseline | See §7 | ☐ |
| 4.1.10 | **Drop test databases** | Discard all test changes | `DROP DATABASE PLYMOUTH_PROD_TEST` / `PLYMOUTH_ANALYTICS_TEST` | ☐ |
| 4.1.11 | **Verify Virginia is still healthy primary** | Confirm nothing changed | `SHOW FAILOVER GROUPS` on NoVA | ☐ |
| 4.1.12 | **Resume HVR** | Restart ingest; confirm writes flow to Virginia | Musawar / HVR team | ☐ |
| 4.1.13 | **Resume replication schedule** | Confirm FG_PLYMOUTH_DB schedule is still 5 MINUTE | `SHOW FAILOVER GROUPS` — verify SQL | ☐ |
| 4.1.14 | **Post-test baseline snapshot on Virginia** | Diff against pre-test — must be identical | See §7 | ☐ |
| 4.1.15 | **Notify stakeholders** | Test complete / results | Rajan | ☐ |

### 4.2 Mode B SQL (run on the **Ohio DR account**, us-east-2)

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §4.2 MODE B — CLONE-AND-TEST (Execute on Ohio, us-east-2)
-- ═══════════════════════════════════════════════════════════════════════════
USE ROLE ACCOUNTADMIN;

-- 1. Verify Ohio is a healthy secondary; force a final refresh
ALTER FAILOVER GROUP FG_PLYMOUTH_DB REFRESH;

SHOW REPLICATION DATABASES;
SELECT name, last_refresh_status, last_refresh_end_time
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('FG_PLYMOUTH_DB'))
ORDER BY last_refresh_end_time DESC LIMIT 3;
-- Expected: last_refresh_status = SUCCEEDED

-- 2. Zero-copy clone the replicated databases (instant, fully writable)
CREATE DATABASE PLYMOUTH_PROD_TEST CLONE PLYMOUTH_PROD;
CREATE DATABASE PLYMOUTH_ANALYTICS_TEST CLONE PLYMOUTH_ANALYTICS;

-- 3. (Optional) Re-create non-replicated objects from IaC for end-to-end testing
--    (hybrid tables, external tables, event tables) — accept the gap or script them.
--    Inbound-share deps can't be cloned — validate via §8.

-- 4. Grant test-runner role access to the clones (tailor to Plymouth's RBAC)
GRANT USAGE ON DATABASE PLYMOUTH_PROD_TEST TO ROLE <PLYMOUTH_TEST_RUNNER_ROLE>;
GRANT USAGE ON ALL SCHEMAS IN DATABASE PLYMOUTH_PROD_TEST TO ROLE <PLYMOUTH_TEST_RUNNER_ROLE>;
GRANT SELECT ON ALL TABLES IN DATABASE PLYMOUTH_PROD_TEST TO ROLE <PLYMOUTH_TEST_RUNNER_ROLE>;
GRANT SELECT ON FUTURE TABLES IN DATABASE PLYMOUTH_PROD_TEST TO ROLE <PLYMOUTH_TEST_RUNNER_ROLE>;
-- Repeat for PLYMOUTH_ANALYTICS_TEST

-- 5. Run the test plan against the clones (§9). Reads/writes on the clones don't affect
--    the actual secondary or the Virginia primary.

-- 6. Validate external-stage S3 reachability (proves Ohio IAM trust is configured)
-- LIST @PLYMOUTH_PROD_TEST.<schema>.<external_stage>;
-- "access denied" => Ohio IAM identity is missing trust policy on S3 bucket (best-practices §4.1)

-- 7. Drop test databases when complete — discards all Ohio test changes
DROP DATABASE PLYMOUTH_PROD_TEST;
DROP DATABASE PLYMOUTH_ANALYTICS_TEST;

-- 8. Defensive verification — Virginia should still be primary throughout
SHOW FAILOVER GROUPS;  -- FG_PLYMOUTH_DB primary should still be <PLYMOUTH_PROD> (NoVA)
```

> **Why this is safe.** Virginia is never demoted, the connection URL is never flipped, DNS is untouched, HVR reconnects to Virginia, and Tableau sees no interruption. Blast radius is the throwaway clones, which are dropped at test end.

---

## 5. Mode A — Failover (Virginia → Ohio)

> **Use this when** rehearsing (or responding to) a real regional outage. This promotes `FG_ACCOUNT_LEVEL` + `FG_PLYMOUTH_DB` to Ohio. **`FG_NON_PLYMOUTH_DBS` is intentionally NOT promoted.** Schedule after the legacy DW is retired.

### 5.1 Failover steps

| Step | Description | Action | Est. time | Status |
|---|---|---|---|---|
| 5.1.1 | **Declare** | Musawar authorizes the Plymouth failover | 1–5 min | ☐ |
| 5.1.2 | Stop HVR and all write activity on Virginia (if reachable) | Pause HVR ingest + external schedulers | 1–2 min | ☐ |
| 5.1.3 | Final refresh (if Virginia is still reachable) | `ALTER FAILOVER GROUP FG_PLYMOUTH_DB REFRESH` | 1–3 min | ☐ |
| 5.1.4 | Promote account-level group on Ohio | `ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL PRIMARY` (on Ohio) | 1–2 min | ☐ |
| 5.1.5 | Promote workload DB group on Ohio | `ALTER FAILOVER GROUP FG_PLYMOUTH_DB PRIMARY` (on Ohio) | 1–2 min | ☐ |
| 5.1.6 | Promote the Connection on Ohio | `ALTER CONNECTION PLYMOUTH_CONN PRIMARY` (on Ohio) | < 1 min | ☐ |
| 5.1.7 | *(If PrivateLink)* **Manual DNS CNAME flip** | Repoint `snowflake.plymouth.<your-domain>` **and the OCSP URL** CNAME records to Ohio endpoint | 2–5 min | ☐ |
| 5.1.8 | *(If PrivateLink)* Wait for DNS TTL | 60–300 s | 1–5 min | ☐ |
| 5.1.9 | Resume HVR targeting the Connection URL | HVR writes now go to Ohio primary | 1–2 min | ☐ |
| 5.1.10 | Verify Snowflake Tasks schedule on Ohio | `SHOW TASKS IN DATABASE PLYMOUTH_PROD` on Ohio | 1–2 min | ☐ |
| 5.1.11 | Validate external S3 stages on Ohio | `LIST @stage` | 2–5 min | ☐ |
| 5.1.12 | Validate app connectivity via connection URL | Tableau smoke test (Robert Gay) | 5–10 min | ☐ |
| 5.1.13 | Confirm non-Plymouth DBs still read-write on Virginia | `SHOW DATABASES` on Virginia | 1–2 min | ☐ |
| 5.1.14 | Notify stakeholders | Paul Lobello / Rajan sign-off | 1–2 min | ☐ |

### 5.2 Failover SQL (run on **Ohio**, us-east-2)

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §5.2 MODE A — FAILOVER (Execute on Ohio, us-east-2)
-- ═══════════════════════════════════════════════════════════════════════════
USE ROLE ACCOUNTADMIN;

-- 1. Optional final refresh (only if Virginia is still reachable)
ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL REFRESH;
ALTER FAILOVER GROUP FG_PLYMOUTH_DB REFRESH;

-- 2. Promote account-level group FIRST (roles/warehouses Plymouth's databases depend on)
ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL PRIMARY;

-- 3. Promote Plymouth's database group
ALTER FAILOVER GROUP FG_PLYMOUTH_DB PRIMARY;

-- 4. Promote the Connection so the URL resolves to Ohio
ALTER CONNECTION PLYMOUTH_CONN PRIMARY;

-- 5. Verify promotion
SHOW FAILOVER GROUPS;   -- FG_ACCOUNT_LEVEL + FG_PLYMOUTH_DB primary = PLYMOUTH_PROD_DR (Ohio)
SHOW CONNECTIONS;       -- PLYMOUTH_CONN is_primary = true on Ohio

-- 6. DO NOT promote FG_NON_PLYMOUTH_DBS — those databases stay on Virginia.

-- 7. Verify Snowflake Tasks are scheduled (tasks replicate in resumed state)
SHOW TASKS IN DATABASE PLYMOUTH_PROD;
SHOW TASKS IN DATABASE PLYMOUTH_ANALYTICS;
-- ALTER TASK PLYMOUTH_PROD.<schema>.<task> RESUME;  -- if any appear suspended

-- 8. Validate an external S3 stage (confirms Ohio IAM trust policy is configured)
-- LIST @PLYMOUTH_PROD.<schema>.<external_stage>;
```

```
-- ─────────────────────────────────────────────────────────────────────────────
-- §5.1.7  MANUAL DNS CNAME FLIP (if PrivateLink) — network team
-- ─────────────────────────────────────────────────────────────────────────────
-- Repoint BOTH records from NoVA to Ohio:
--   snowflake.plymouth.<your-domain>   ->  <PLYMOUTH_OHIO_PE>  (was <PLYMOUTH_NOVA_PE>)
--   ocsp.<...>.privatelink...          ->  <PLYMOUTH_OHIO_PE>
-- TTL must already be 60–300s.
-- Flipping only the connection URL CNAME (not OCSP) causes TLS validation failures.
```

---

## 6. Mode A — Failback (Ohio → Virginia)

Once Virginia / us-east-1 is healthy, fail back.

| Step | Description | Action | Est. time | Status |
|---|---|---|---|---|
| 6.1 | Confirm Virginia restored | Health check | 5–10 min | ☐ |
| 6.2 | Refresh Virginia from Ohio | `ALTER FAILOVER GROUP FG_PLYMOUTH_DB REFRESH` on Virginia | 10–30 min | ☐ |
| 6.3 | Stop HVR writes on Ohio | Pause HVR ingest | 1–2 min | ☐ |
| 6.4 | Final refresh to Virginia | `ALTER FAILOVER GROUP FG_PLYMOUTH_DB REFRESH` | 1–3 min | ☐ |
| 6.5 | Promote account-level group on Virginia | `ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL PRIMARY` (on Virginia) | 1–2 min | ☐ |
| 6.6 | Promote Plymouth DB group on Virginia | `ALTER FAILOVER GROUP FG_PLYMOUTH_DB PRIMARY` (on Virginia) | 1–2 min | ☐ |
| 6.7 | Promote Connection on Virginia | `ALTER CONNECTION PLYMOUTH_CONN PRIMARY` (on Virginia) | < 1 min | ☐ |
| 6.8 | *(If PrivateLink)* **Reverse the DNS CNAME flip** | Repoint connection URL + OCSP CNAME back to Virginia | 2–5 min | ☐ |
| 6.9 | *(If PrivateLink)* Wait for DNS TTL | 60–300 s | 1–5 min | ☐ |
| 6.10 | Resume HVR targeting Connection URL | HVR writes go back to Virginia primary | 1–2 min | ☐ |
| 6.11 | Verify Snowflake Tasks schedule on Virginia | `SHOW TASKS` | 1–2 min | ☐ |
| 6.12 | Validate connectivity via connection URL | Tableau smoke test | 5–10 min | ☐ |
| 6.13 | Resume Ohio replication schedule | `ALTER FAILOVER GROUP FG_PLYMOUTH_DB RESUME` (if needed) | < 1 min | ☐ |
| 6.14 | Notify stakeholders | Rajan / Paul Lobello sign-off | 1–2 min | ☐ |

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §6 MODE A — FAILBACK (Execute on Virginia, us-east-1)
-- ═══════════════════════════════════════════════════════════════════════════
USE ROLE ACCOUNTADMIN;
ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL REFRESH;
ALTER FAILOVER GROUP FG_PLYMOUTH_DB REFRESH;
-- (stop HVR on Ohio, then final refresh)
ALTER FAILOVER GROUP FG_ACCOUNT_LEVEL PRIMARY;
ALTER FAILOVER GROUP FG_PLYMOUTH_DB PRIMARY;
ALTER CONNECTION PLYMOUTH_CONN PRIMARY;
SHOW FAILOVER GROUPS;   -- primary = PLYMOUTH_PROD (NoVA)
SHOW CONNECTIONS;       -- PLYMOUTH_CONN is_primary = true on Virginia
-- Reverse the DNS CNAME flip (network team): snowflake.plymouth.<your-domain> + OCSP -> Virginia
```

---

## 7. Baseline / post-test snapshot (run on Virginia before AND after)

Run before the Mode B test and again after; diff the outputs — they must be identical, proving the test left Virginia unchanged.

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §7 BASELINE / POST-TEST SNAPSHOT — run on Virginia (NoVA primary)
-- ═══════════════════════════════════════════════════════════════════════════
USE ROLE ACCOUNTADMIN;

-- 1. Plymouth database object counts
SELECT TABLE_SCHEMA, COUNT(*) AS table_count, SUM(ROW_COUNT) AS rows, SUM(BYTES) AS bytes
FROM PLYMOUTH_PROD.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
GROUP BY 1 ORDER BY 1;

SELECT TABLE_SCHEMA, COUNT(*) AS table_count, SUM(ROW_COUNT) AS rows, SUM(BYTES) AS bytes
FROM PLYMOUTH_ANALYTICS.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA <> 'INFORMATION_SCHEMA'
GROUP BY 1 ORDER BY 1;

-- 2. Failover group state
SHOW FAILOVER GROUPS;
SELECT name, last_refresh_status, last_refresh_end_time,
       DATEDIFF('second', last_refresh_end_time, CURRENT_TIMESTAMP()) AS seconds_ago
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('FG_PLYMOUTH_DB'))
ORDER BY last_refresh_end_time DESC LIMIT 3;

-- 3. Connection state
SHOW CONNECTIONS;  -- PLYMOUTH_CONN is_primary must be true on Virginia

-- 4. Account-level object counts (covered by FG_ACCOUNT_LEVEL)
SELECT COUNT(*) AS roles FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES WHERE DELETED_ON IS NULL;
SELECT COUNT(*) AS users FROM SNOWFLAKE.ACCOUNT_USAGE.USERS WHERE DELETED_ON IS NULL;
SHOW WAREHOUSES;

-- 5. Replication usage — check for unexpected spike
SELECT start_time, end_time, database_name, bytes_transferred, credits_used
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_USAGE_HISTORY(
    DATE_RANGE_START => DATEADD('hour', -3, CURRENT_TIMESTAMP())))
ORDER BY start_time DESC;

-- 6. Failover group refresh schedule — must still be 5 MINUTE (not 10)
SHOW FAILOVER GROUPS;
-- Alert if REPLICATION_SCHEDULE shows '10 MINUTE' — known GUI bug; fix via SQL
```

---

## 8. Inbound data shares — pre-test resolution

Inbound-share databases **cannot be replicated**. For each share feeding PLYMOUTH_PROD / PLYMOUTH_ANALYTICS, resolve before the test:

| Provider / Share | Workload dependency | Resolution | Ohio-side present? | Status |
|---|---|---|---|---|
| *(audit required — Pulugundla)* | — | Auto-Fulfillment / Dual-share | ☐ | ☐ |

**Options:** (1) **Auto-Fulfillment** — provider auto-fulfills the share into us-east-2 (Ohio); (2) **Dual share** — provider shares to both the NoVA production account **and** the Ohio DR account.

```sql
-- On the Ohio DR account — confirm each required inbound share appears
SHOW SHARES;  -- kind = INBOUND
-- SELECT COUNT(*) FROM <shared_db>.<schema>.<table>;  -- confirm queryable
```

---

## 9. Test plan (run against Ohio clones in Mode B)

| # | Test | Method | Pass criteria |
|---|---|---|---|
| 9.1 | Data parity — row counts (Tier 1 first, §1.4.4) | `COUNT(*)` on Tier 1 tables vs Virginia | Match (modulo HVR-pause delta) |
| 9.2 | Data parity — checksums (Tier 1) | `HASH_AGG(*)` on a deterministic projection | Hash matches |
| 9.3 | Dynamic tables | Confirm reinitialize + refresh on Ohio | First refresh completes |
| 9.4 | External S3 stages | `LIST @stage` + read a file | Files reachable (Ohio IAM trust works) |
| 9.5 | Snowpipe (if any) | Drop test file in Ohio S3 container | Auto-ingest fires (SNS/SQS configured) |
| 9.6 | Standard streams | Verify stream offsets on Ohio | Streams usable |
| 9.7 | Tasks | Confirm in-scope tasks schedule on Ohio | Triggerable; owning roles present |
| 9.8 | RBAC fidelity | Log in as several Plymouth roles; check visibility + masking | Identical to Virginia |
| 9.9 | Inbound shares | Query shared data on Ohio | Returns expected rows (§8) |
| 9.10 | Hybrid tables | Confirm they are absent on Ohio (expected) | Absent — no error on the clones |
| 9.11 | Streamlit apps (BCR-2316) | Smoke-test each SiS app in Ohio clone via Snowsight | App renders + read-only ops succeed |
| 9.12 | Time travel | Confirm time travel on Ohio clone is empty (starts fresh) | Zero history before failover moment |
| 9.13 | Cost | Inspect replication credits for the window | Within forecast |

---

## 10. Roles & responsibilities

| Role | Person | Responsibility |
|---|---|---|
| Test Lead | **Musawar Nadeem** | Owns the test plan and go/no-go decision |
| Test Engineer (primary) | **Pulugundla Narasimham** | Executes SQL, monitors progress |
| Architecture / Approvals | **Rajan Rajanagan** | Approves the runbook and gating decisions |
| Engineering support | **Robert Gay** | Tableau and downstream consumer validation |
| Operations / Backups | **Jill Weigand** | Backup strategy follow-up (Temporal Archive) |
| Observer / Sign-off | **Paul Lobello** | Performance sign-off |
| Snowflake Account / Architecture | **Steve Mitchener (Snowflake)** | Runbook authorship, escalations, open items |
| Snowflake Product Liaison | **Tom Smith (Snowflake)** | Product-side issues (GUI bug, BCR-2316, version uplift) |
| Snowflake Support | **AAA Ninja + Help Desk** | On-call during the test window |

---

## 11. Known constraints & Plymouth-specific watch-outs

| # | Item | Detail |
|---|---|---|
| 11.1 | *(If PrivateLink)* Connectivity breaks auto-redirect | Every failover needs a **manual DNS CNAME change** — dominant RTO component. |
| 11.2 | OCSP URL must also be flipped | Flipping only the connection CNAME causes TLS validation failures. |
| 11.3 | DNS TTL lowered in advance | Set 60–300s before any drill; can't help retroactively. |
| 11.4 | Append-only streams block refresh | Must be zero in PLYMOUTH_PROD / PLYMOUTH_ANALYTICS before the group is created. |
| 11.5 | Hybrid tables not replicated (Plymouth-confirmed) | Remain on NoVA; absent on Ohio. Map all downstream dependencies. |
| 11.6 | External / event tables don't replicate | External tables skipped silently. Map dependencies. |
| 11.7 | Internal-stage files >5 GB fail refresh | Audit stage file sizes; enable directory tables if files must replicate. |
| 11.8 | Ohio IAM identity is different from NoVA | Storage integration replicates; Ohio IAM ARN must be added to S3 bucket trust policies separately. |
| 11.9 | Snowpipe plumbing not replicated (if Snowpipe used) | SNS/SQS plumbing must be built on Ohio. Plymouth uses HVR — confirm Snowpipe count. |
| 11.10 | Inbound shares not replicable | Auto-fulfillment or dual share required per provider (§8). |
| 11.11 | **GUI schedule display bug** (Plymouth-confirmed) | Snowsight shows 10 min even after ALTER to 5 min. Always use SQL; adding a DB via GUI resets to 10 min. Tom Smith tracking fix. |
| 11.12 | Check dangling references before every refresh | `REPLICATION_GROUP_DANGLING_REFERENCES('FG_PLYMOUTH_DB')` — resolve `IS_BLOCKING_REFRESH = TRUE`. |
| 11.13 | Time travel history does not replicate | Ohio time travel starts fresh at failover moment. NoVA history is preserved (read-only secondary). Expected behavior. |
| 11.14 | HVR cross-region latency (minimal) | Steve confirmed: AWS-to-AWS egress latency between NoVA and Ohio is minimal. HVR writes to Ohio primary will not see material degradation. |

---

## 11.2 Streamlit-in-Snowflake replication (BCR-2316, 2026_04 bundle)

> **Note (doc refresh — BCR-2316).** As of the April 2026 behavior change bundle, Streamlit-in-Snowflake objects replicate automatically with their containing database. Plymouth previously identified this as a gap (meeting 1:59 — Pulugundla, Snowflake version 10.5). This gap is now closed.

### 11.2.1 What changes with BCR-2316

| | Before BCR-2316 | After BCR-2316 |
|---|---|---|
| SiS objects in replicated DB | NOT replicated | Replicated automatically with the DB |
| Plymouth deployment pattern | Deploy SiS from IaC into each account separately | Deploy SiS to NoVA once; Snowflake replicates to Ohio |
| Opt-out | n/a | `ALTER ACCOUNT SET ENABLE_STREAMLIT_REPLICATION = FALSE` |

### 11.2.2 What still does NOT replicate (account-level dependencies)

| Dependency | Plymouth status | Required action |
|---|---|---|
| **Compute Pools** | Only relevant if any SiS app uses Snowpark Container Services | Enumerate apps; verify pool exists on Ohio with same name |
| **Warehouses** | ✅ Replicated by FG_ACCOUNT_LEVEL on BC | None — existing FG covers |
| **Roles** | ✅ Replicated by FG_ACCOUNT_LEVEL on BC | Verify owning role for each app exists on Ohio |
| **External Access Integrations** | Confirm whether any SiS app references EAI | If yes, recreate on Ohio with same name |
| **Secrets** | Confirm whether any SiS app references a secret | If yes, replicate at account level or recreate on Ohio |
| **Owner role** | If owner not yet replicated → ACCOUNTADMIN temporarily owns | Ensure owning role is in FG_ACCOUNT_LEVEL scope |

### 11.2.3 Verification SQL — pre-test (run on both NoVA and Ohio)

```sql
-- ═══════════════════════════════════════════════════════════════════════════
-- §11.2.3a — Confirm BCR-2316 is active
-- ═══════════════════════════════════════════════════════════════════════════
SHOW PARAMETERS LIKE 'ENABLE_STREAMLIT_REPLICATION' IN ACCOUNT;
-- Expected: TRUE. If FALSE: ALTER ACCOUNT SET ENABLE_STREAMLIT_REPLICATION = TRUE;

SELECT SYSTEM$BEHAVIOR_CHANGE_BUNDLE_STATUS('2026_04');
-- Expected: ENABLED. If DISABLED: SELECT SYSTEM$ENABLE_BEHAVIOR_CHANGE_BUNDLE('2026_04');

-- ═══════════════════════════════════════════════════════════════════════════
-- §11.2.3b — Inventory all Streamlit apps in Plymouth's replicated DBs
-- ═══════════════════════════════════════════════════════════════════════════
SHOW STREAMLITS IN DATABASE PLYMOUTH_PROD;

SELECT streamlit_name, schema_name, database_name, owner_role_type, owner,
       query_warehouse, main_file, url_id, created_on, last_altered
FROM SNOWFLAKE.ACCOUNT_USAGE.STREAMLITS
WHERE database_name = 'PLYMOUTH_PROD' AND deleted IS NULL
ORDER BY created_on DESC;

-- ═══════════════════════════════════════════════════════════════════════════
-- §11.2.3c — Map dependency surface for each SiS app
-- ═══════════════════════════════════════════════════════════════════════════
-- Per-app dependency dump (run for each app):
DESCRIBE STREAMLIT <DB>.<SCHEMA>.<APP_NAME>;
-- Inspect: external_access_integrations, secrets, query_warehouse, owner.

-- Account-level dependency inventory:
SHOW WAREHOUSES;
SHOW ROLES;
SHOW EXTERNAL ACCESS INTEGRATIONS;
SHOW SECRETS;
SHOW COMPUTE POOLS;
```

### 11.2.4 Verification SQL — during Mode B test (on Ohio clone)

```sql
-- After clones exist on Ohio:
USE DATABASE PLYMOUTH_PROD_TEST;
SHOW STREAMLITS IN DATABASE PLYMOUTH_PROD_TEST;
-- Each replicated SiS app should appear with:
--   ✓ Same fully-qualified name as on NoVA
--   ✓ Same main_file
--   ✓ Same query_warehouse (provided the warehouse exists on Ohio)
--   ✓ Same Python files in its stage

-- Smoke test (manual): in Snowsight on Ohio → Projects → Streamlit → open app → confirm renders + read-only ops
-- DO NOT run write ops against PLYMOUTH_PROD (the actual secondary). Only against PLYMOUTH_PROD_TEST clone.
```

### 11.2.5 Plymouth action items — Streamlit replication

| # | Action | Owner | When |
|---|---|---|---|
| 11.2-A | Confirm `ENABLE_STREAMLIT_REPLICATION = TRUE` on both NoVA and Ohio | Pulugundla | T-14d |
| 11.2-B | Verify 2026_04 BCR bundle is ENABLED | Pulugundla | T-14d |
| 11.2-C | Inventory all SiS apps in replicated DBs using §11.2.3b SQL | Pulugundla | T-14d |
| 11.2-D | For each SiS app, map Compute Pool / EAI / Secret / owning-role dependencies | Pulugundla + Snowflake Team | T-14d |
| 11.2-E | Verify each account-level dependency exists on Ohio with the same name | Pulugundla | T-7d |
| 11.2-F | During Mode B test, validate SiS apps render + run read-only in the clones (§11.2.4) | Pulugundla | T+0 |
| 11.2-G | Capture any apps that failed to render + the missing dependency | Pulugundla | T+0 |
| 11.2-H | Update Plymouth's SiS deployment standard: rely on replication for DR; IaC for account-level deps only | Snowflake Team + Pulugundla | T+30d |

---

## 12. Open items tracker

| # | Item | Owner | Due | Status |
|---|---|---|---|---|
| 1 | Fill in Plymouth org name, NoVA account locator, Ohio account locator (§1.2) | Pulugundla | T-7d | ☐ |
| 2 | Confirm test mode = Mode B; confirm connection object name + connectivity type (public or PrivateLink) | Musawar | T-7d | ☐ |
| 3 | Complete object audit; resolve append-only streams + dangling references; map hybrid/external table deps | Pulugundla | T-7d | ☐ |
| 4 | Enumerate inbound shares; resolve each with auto-fulfillment or dual share (§8) | Pulugundla | T-7d | ☐ |
| 5 | Verify HVR + Tableau + all writers/readers on the connection URL | Musawar + Robert Gay | T-7d | ☐ |
| 6 | Grant Ohio DR IAM identity IAM trust policy on all S3 buckets (§5.2) | Pulugundla (AWS IAM admin) | T-7d | ☐ |
| 7 | Confirm Snowpipe object count; if non-zero, build SNS/SQS plumbing on Ohio | Pulugundla | T-7d | ☐ |
| 8 | Complete BCR-2316 / Streamlit dependency mapping (§11.2-A through E) | Pulugundla + Snowflake Team | T-14d | ☐ |
| 9 | *(If PrivateLink)* Pre-stage private endpoints + DNS CNAMEs (connection + OCSP); set TTL 60–300s | Network team | T-7d | ☐ |
| 10 | Run BCDR churn analytics (§1.4) and confirm 5-min RPO / 15-min RTO is achievable | Pulugundla + Snowflake Team | T-14d | ☐ |
| 11 | Run pre-flight SQL (§3.4) and save baseline snapshot | Pulugundla | T-1h | ☐ |
| 12 | Post-test snapshot + diff against pre-test baseline | Pulugundla | T+0 | ☐ |
| 13 | File GUI schedule display bug with Snowflake product; add CI check for schedule drift | Tom Smith + Pulugundla | T-30d | ☐ |
| 14 | Schedule Mode B test window (Sat/Sun); engage AAA Ninja ≥7 days ahead | Rajan + Snowflake Team | T-7d | ☐ |
| 15 | Schedule Mode A real-DR rehearsal after legacy DW retirement | Musawar + Snowflake Team | T+90d | ☐ |

---

*Runbook authored by Steve Mitchener (Snowflake), May 2026. Based on the May 14, 2026 working session with Plymouth. Adapts the canonical Snowflake BCDR runbook to Plymouth's Business Critical / AWS us-east-1 ↔ us-east-2 environment and Plymouth's non-destructive test requirement. Living document — revise after each test cycle and as open items close.*
