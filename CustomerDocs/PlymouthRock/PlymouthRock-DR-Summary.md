# Plymouth Rock — Disaster Recovery Planning Summary

> **Scope.** DR for the Plymouth Rock Snowflake environment on **AWS**, with production in **us-east-1 (Northern Virginia)** and a DR account in **us-east-2 (Ohio)**. Covers the full account: PLYMOUTH_PROD, PLYMOUTH_ANALYTICS, and all account-level objects. Plymouth owns the account; there are no unrelated third-party tenants.
>
> **Edition.** Business Critical — confirmed (Musawar Nadeem, meeting 29:08). Required for Failover Groups and Client Redirect.
>
> **Test posture.** Plymouth's May 2026 test is **Mode B (Non-Destructive)**: clone the replicated databases on Ohio, validate, discard. Mode A (real end-to-end failover) is planned after the legacy data warehouse is retired.
>
> **Companion documents.** `PlymouthRock-DR-Best-Practices.md` · `PlymouthRock-DR-Failover-Failback-Runbook.md`

---

## 1. The problem this design solves

Plymouth Rock needs regional DR for its Snowflake data platform. Production runs on a Business Critical account in AWS us-east-1 (Northern Virginia), with HVR as the primary ingest tool. The design must:

- Protect PLYMOUTH_PROD and PLYMOUTH_ANALYTICS against a regional outage.
- Give HVR and Tableau a **stable connection URL** that redirects automatically at failover, without application teams changing connection strings.
- Support a **non-destructive test** mode that validates DR readiness without overwriting the Virginia primary.

Plymouth's planned test is **Mode B**: fail over to Ohio, validate against clones, discard all Ohio changes, then resume normal replication. Virginia must return to primary state "as if nothing happened."

---

## 2. Proposed approach — failover groups

| # | Failover Group | Contents | Purpose |
|---|---|---|---|
| 1 | **`FG_ACCOUNT_LEVEL`** | Users, roles, warehouses, resource monitors, network policies, integrations | Shared account infrastructure; fails over with the data databases. |
| 2 | **`FG_PLYMOUTH_DB`** | `PLYMOUTH_PROD`, `PLYMOUTH_ANALYTICS`, and dependent objects | Core data platform — the primary DR scope. |
| 3 | **`FG_NON_PLYMOUTH_DBS`** *(if applicable)* | Any other databases not in the primary DR scope | Catalogued but not promoted; stays read-write on production. |

> **Note.** Plymouth is the sole owner of this account. `FG_ACCOUNT_LEVEL` promotion causes a brief **administrative DDL freeze** on production (no CREATE/ALTER/DROP for roles, users, warehouses). Running queries and DML against read-write databases are unaffected. Plymouth's operations team should confirm this is acceptable before the Mode A drill.

> **GUI warning.** The Snowsight failover-group editor has a known display bug: after `ALTER FAILOVER GROUP ... SET REPLICATION_SCHEDULE = '5 MINUTE'`, the UI still shows 10 minutes. The actual cadence is correct. **Always use SQL** for all failover-group changes. Adding a database via the GUI resets the interval to 10 minutes. (Tom Smith/Snowflake product team are tracking this for a fix.)

---

## 3. Client Redirect (stable connection URL)

A named **Connection** object provides a stable URL that redirects to Ohio at failover without application teams changing connection strings.

| Item | Value |
|---|---|
| Connection name | `PLYMOUTH_CONN` *(confirm exact name)* |
| Connection URL | `snowflake.plymouth.<your-domain>` *(confirm)* |
| Scope | **All Plymouth workload writers and readers.** |

> **Hard prerequisite.** Every pipeline, ETL job (including HVR), and BI tool (Tableau and others) that **writes to or reads from** PLYMOUTH_PROD / PLYMOUTH_ANALYTICS must be migrated from the raw account URL to the connection URL **before** the first DR test. Client Redirect cannot protect a connection that bypasses it. Musawar confirmed HVR's connection target must be the Connection URL, not the raw account URL (runbook §3.1).

> **Note (doc refresh).** If Plymouth uses the **PrivateLink** variant of the connection URL (`<org>-<connection>.privatelink.snowflakecomputing.com`), Client Redirect does **not** happen automatically — a manual DNS CNAME flip (plus the OCSP URL) is required at every failover. See §8. Confirm whether Plymouth's `snowflake.plymouth.<your-domain>` CNAME resolves to the public org URL or the PrivateLink URL.

---

## 4. DR account placement

Plymouth's DR account is in **AWS us-east-2 (Ohio)**, in the same Snowflake organization. This satisfies the requirement for a different region in the same org.

| Component | Value |
|---|---|
| Org | `<PLYMOUTH_ORG>` *(confirm)* |
| Production account locator | `<PLYMOUTH_PROD>` *(Pulugundla to fill — runbook Open Item 1)* |
| DR account locator | `<PLYMOUTH_PROD_DR>` *(Pulugundla to fill — runbook Open Item 1)* |

---

## 5. Replication feasibility — the object audit

Before any replication group is created (or before the May 2026 test), `PLYMOUTH_PROD` and `PLYMOUTH_ANALYTICS` must be audited object-by-object.

### 5.1 Replication support matrix

| Component | Replicable | Plymouth-specific action |
|---|---|---|
| Permanent & transient tables | ✅ Yes | Standard |
| Dynamic tables | ✅ Yes | First refresh on Ohio is a full reinitialization |
| External stages | ✅ (definition) | DR IAM role trust must be pre-configured on the **same S3 buckets** |
| Internal stages | ✅ (with caveats) | Directory table enabled to replicate files; **no file > 5 GB** |
| Storage integrations | ✅ (object) | **Ohio DR account has a different IAM identity** — must add IAM role trust policy on each S3 bucket (one-time cloud IAM) |
| Pipes / Snowpipe | ✅ (object) | Plymouth uses **HVR** (not Snowpipe) as primary ingest — confirm whether any Snowpipe objects exist; if yes, SNS/SQS plumbing must be rebuilt on Ohio |
| Streams (standard) | ✅ Yes | Source must be in the same group / database |
| **Streams (append-only)** | ❌ No | **Must be zero in PLYMOUTH_PROD / PLYMOUTH_ANALYTICS before the group is created — blocks refresh** |
| Tasks | ✅ Yes | Must have run once; owning roles in `FG_ACCOUNT_LEVEL` |
| External tables | ❌ No | **Skipped silently** — map dependencies before the first drill |
| **Hybrid tables** | ❌ No | **Plymouth has hybrid tables (confirmed, meeting 1:59 — Pulugundla).** They remain on NoVA; they will NOT appear on Ohio. Map every downstream view/task that joins them. |
| Event tables | ❌ No | DMF results/history won't exist on Ohio |
| **Inbound datashare databases** | ❌ No | Audit required — see §6 |
| Masking / row-access policies | ✅ Yes | — |
| Tags | ✅ Yes | Cannot be modified on Ohio DR side |
| Stored procedures & UDFs | ✅ Yes | Replicate any external-network access integrations too |
| **Streamlit apps** | ✅ Yes (BCR-2316) | See note below |

> **Note (doc refresh — BCR-2316, 2026_04 bundle).** Streamlit-in-Snowflake replication is now **enabled by default** as of the April 2026 behavior change bundle. Plymouth previously identified Streamlit replication as a gap (Pulugundla, meeting 1:59 — Snowflake version 10.5). With BCR-2316 active, SiS objects replicate automatically with their containing database. **Plymouth must verify**: (1) `ENABLE_STREAMLIT_REPLICATION = TRUE` on both NoVA and Ohio, and (2) account-level dependencies (Compute Pools, External Access Integrations, Secrets, owning roles) exist on Ohio with the same names. Warehouses and roles are already covered by `FG_ACCOUNT_LEVEL`.

> **Time travel.** The *retention setting* replicates; the *historical change records* do not. After failover, time travel on Ohio starts fresh from that moment. Time travel on NoVA is preserved (NoVA becomes a read-only secondary; its data is intact). Plymouth has up to 15-day retention on some tables (meeting 15:08 — Pulugundla). This is expected behavior, not a bug.

> **Fail-safe.** Same pattern as time travel — settings replicate, accumulated fail-safe data does not.

> Run `SELECT * FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_DANGLING_REFERENCES('FG_PLYMOUTH_DB'))` and resolve every row where `IS_BLOCKING_REFRESH = TRUE` before the first refresh.

> **Note (doc refresh — BCR-1555, 2024_02 bundle).** Dangling reference errors in refresh operations are now **aggregated**: all blocking references are surfaced simultaneously, and the refresh fails before any secondary objects are updated (no more partial-refresh state). Use this to fix all blocking references in one pass.

### 5.2 Storage integration nuance (AWS)

- The storage-integration **object** replicates automatically.
- The Ohio DR account uses a **different IAM identity** (different IAM user/role ARN) than NoVA.
- That identity must be added to the **IAM role trust policy** on each S3 bucket used by PLYMOUTH_PROD / PLYMOUTH_ANALYTICS — a one-time AWS IAM step before the first drill.
- If the **S3 bucket region itself** fails, external-stage files are unavailable regardless of which Snowflake account is primary. S3 Cross-Region Replication (CRR) is a separate AWS concern.

### 5.3 BCDR analytics: grounding the 5-minute RPO

Plymouth's agreed RPO is **5 minutes** (refresh interval) and RTO is **15 minutes**. Run the analytics below before the first drill to confirm these are achievable and affordable.

| Analytic | Feeds | Plymouth relevance |
|---|---|---|
| **Table churn** (fail-safe ÷ active bytes) | **RPO + RTO** | Identifies which tables put the most data at risk between 5-minute refreshes; these are Plymouth's "Tier 1" tables. |
| **Database churn ratio** | **RTO** | Confirms whether PLYMOUTH_PROD's volatility supports a 15-minute RTO. |
| **Transient-table flag** | **RPO** | Transient tables have no fail-safe — changes since the last refresh are unrecoverable. |
| **Replication volume + cost** | **RPO feasibility** | Whether a 5-minute cadence is sustainable given Plymouth's data churn. |
| **Refresh schedule** | **RPO (definition)** | Confirm the FG_PLYMOUTH_DB cadence is actually 5 minutes (GUI shows 10 — verify via SQL). |

Full query set in the runbook §1.4.

---

## 6. Inbound data shares — audit required

Databases created from an **inbound** data share **cannot be replicated**. Plymouth must audit all inbound shares feeding PLYMOUTH_PROD / PLYMOUTH_ANALYTICS and resolve each by:
1. **Auto-Fulfillment** — provider auto-fulfills the share into us-east-2 (Ohio), or
2. **Dual share** — provider shares to both the NoVA production account **and** the Ohio DR account.

Track per-provider to closure before Plymouth can claim full DR coverage.

---

## 7. Impact on workloads during a Plymouth failover

When `FG_ACCOUNT_LEVEL` + `FG_PLYMOUTH_DB` are promoted to Ohio:

| Affected component | Behavior during the window |
|---|---|
| PLYMOUTH_PROD / PLYMOUTH_ANALYTICS on NoVA | Become **read-only**. HVR writes, Snowflake Tasks, and any other writer still targeting NoVA directly will **fail**. |
| Account-level objects on NoVA | Become read-only for admin DDL — no CREATE/ALTER/DROP roles, users, warehouses. **Running queries and DML are unaffected.** |
| Databases in `FG_NON_PLYMOUTH_DBS` (if any) | Fully unaffected — stay read-write on NoVA. |
| HVR | Must target the **Connection URL** — redirected to Ohio automatically after failover. |
| Tableau + BI consumers | Must target the **Connection URL** — redirected to Ohio automatically. Robert Gay owns Tableau validation (runbook §12). |
| Snowflake Tasks | Tasks in a *resumed* state replicate with that state. After failover they automatically schedule on Ohio. Validate in the post-failover test plan (runbook §9.7). |

> **Mode B (Plymouth's May 2026 test).** Virginia is never demoted in Mode B. The test uses zero-copy clones on Ohio (PLYMOUTH_PROD_TEST, PLYMOUTH_ANALYTICS_TEST) and validation is against the clones only. All items in this table apply only to a **Mode A** real failover.

---

## 8. Private connectivity + DNS (if PrivateLink)

*(Confirm: does Plymouth's `snowflake.plymouth.<your-domain>` CNAME resolve to the public org URL or a PrivateLink endpoint?)*

If Plymouth uses **AWS PrivateLink**, Client Redirect does **not** happen automatically. Every failover requires a **manual DNS change**:

| Stage | Action |
|---|---|
| Pre-config | Both accounts have their own PrivateLink private endpoint with separate IPs (one-time setup). |
| Pre-config | DNS CNAME for the connection URL **and** the OCSP URL point to NoVA's endpoint (one-time). |
| At failover | Network team **manually updates DNS CNAME records** to point to Ohio's endpoint. |
| At failback | Reverse the CNAME records back to NoVA. |

**Critical details:**
- Every failover needs a manual DNS change — adds to RTO.
- Set DNS **TTL to 60–300 seconds** in advance (cannot help retroactively).
- The **OCSP URL must also be updated**, or TLS certificate validation fails — connections appear broken even after the CNAME flip.

```
snowflake.plymouth.<your-domain> -> <PLYMOUTH_NOVA_PE>    (production, us-east-1)
snowflake.plymouth.<your-domain> -> <PLYMOUTH_OHIO_PE>    (DR, us-east-2)
```

---

## 9. Prerequisites before the first DR drill

1. ✅ Confirm the account is **Business Critical** (confirmed).
2. Confirm failover groups exist with correct membership (`FG_ACCOUNT_LEVEL`, `FG_PLYMOUTH_DB`); verify refresh interval is **5 MINUTE** via SQL (not GUI).
3. Create / confirm the connection object (`PLYMOUTH_CONN`) and **migrate HVR and Tableau** to the connection URL.
4. Complete the object audit (§5); resolve **append-only streams** and all `IS_BLOCKING_REFRESH = TRUE` dangling references; map hybrid-table and external-table dependencies.
5. Grant the Ohio DR IAM identity the **IAM role trust policy** on each S3 bucket used by PLYMOUTH_PROD / PLYMOUTH_ANALYTICS.
6. Confirm whether Snowpipe objects exist; if yes, build SNS/SQS event plumbing on Ohio.
7. Resolve **every inbound data share** (auto-fulfillment or dual share) per provider.
8. Verify **BCR-2316** (`ENABLE_STREAMLIT_REPLICATION = TRUE`) and complete the Streamlit dependency map (§5.1).
9. *(If PrivateLink)* Pre-create private endpoints; pre-stage DNS CNAMEs (connection **and** OCSP URLs); set TTL 60–300s.
10. Schedule the Mode B test window (Saturday or Sunday; Snowflake AAA Ninja support engaged ≥7 days in advance).

---

## 10. Open items

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | Fill in Plymouth org name, production account locator, and Ohio DR account locator (§4) | Pulugundla | ☐ |
| 2 | Confirm connection object name and whether URL is public org URL or PrivateLink (§3, §8) | Musawar | ☐ |
| 3 | Complete PLYMOUTH_PROD + PLYMOUTH_ANALYTICS object inventory; flag append-only streams / external / hybrid / event tables | Pulugundla | ☐ |
| 4 | Enumerate inbound shares; choose auto-fulfillment vs dual share per provider (§6) | Pulugundla | ☐ |
| 5 | Confirm HVR and Tableau (and all other writers/readers) are on the connection URL (§3) | Musawar + Robert Gay | ☐ |
| 6 | Grant Ohio DR IAM identity trust policy on all S3 buckets (§5.2) | Pulugundla (AWS IAM admin) | ☐ |
| 7 | Confirm whether any Snowpipe objects exist; if yes, build SNS/SQS plumbing on Ohio (§5.1) | Pulugundla | ☐ |
| 8 | Verify BCR-2316 bundle enabled; complete Streamlit dependency map (§5.1) | Pulugundla + Snowflake Team | ☐ |
| 9 | *(If PrivateLink)* Pre-stage private endpoints + DNS CNAMEs (connection + OCSP); set TTL 60–300s (§8) | Network team | ☐ |
| 10 | Run BCDR analytics (§5.3) and confirm 5-min RPO / 15-min RTO is achievable | Pulugundla + Snowflake Team | ☐ |
| 11 | Schedule Mode B test window (Sat/Sun); open proactive support case with AAA Ninja ≥7 days prior | Rajan + Snowflake Team | ☐ |
| 12 | After DW retirement: schedule Mode A end-to-end drill | Musawar + Snowflake Team | ☐ |

---

*Tailored from the generic Snowflake BCDR best-practice set for Plymouth Rock. Authored May 2026 (Snowflake Team). Based on the May 14, 2026 working session and Plymouth's existing runbook artifacts. Living document — revise as open items close and after each drill.*
