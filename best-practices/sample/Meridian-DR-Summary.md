# Meridian Financial — Disaster Recovery Planning Summary

> **⚠ Fictional enablement example.** Meridian Financial / "Helios" is invented. See [`README.md`](./README.md).
>
> **Scope.** DR for the Helios workload (`HELIOS_ANALYTICS_PROD`) on the Meridian Financial Snowflake account, on **AWS**, with a DR account in **AWS us-west-2**. Defining constraint: *other applications on the same production account do not have DR plans and must not be disrupted* when Helios fails over.
>
> **Edition.** Failover Groups, **Connection** objects, and **Client Redirect** are **Business Critical Edition** features — confirm the account edition as a prerequisite.
>
> **Companion documents.** [`Meridian-DR-Best-Practices.md`](./Meridian-DR-Best-Practices.md) · [`Meridian-DR-Failover-Failback-Runbook.md`](./Meridian-DR-Failover-Failback-Runbook.md)

---

## 1. The problem this design solves

Helios needs regional DR, but it is a tenant on a **shared production account** (`MERIDIAN_PROD`) alongside other applications that have **no DR requirement**. A single-failover-group design would drag those unrelated workloads into read-only state on every failover or drill.

The plan isolates Helios into its own failover group so it can be promoted to the DR account (`MERIDIAN_DR`, us-west-2) **independently**, without touching the other databases on production.

---

## 2. Proposed approach — independent failover groups

| # | Failover Group | Contents | Purpose |
|---|---|---|---|
| 1 | **`FG_ACCOUNT_LEVEL`** | Users, roles, warehouses, resource monitors, network policies, integrations | Shared account infrastructure; fails over independently of the Helios database. |
| 2 | **`FG_HELIOS_DB`** | `HELIOS_ANALYTICS_PROD` and dependent objects | The Helios workload. Scoped exclusively to Helios — promotable to DR **without affecting other production workloads**. |
| 3 | **`FG_NON_HELIOS_DBS`** | All other production databases not in scope for full DR | Catalogued/replicable but **out of the Helios failover path**. |

> **Why separate groups.** When Helios fails over, only `FG_ACCOUNT_LEVEL` + `FG_HELIOS_DB` are promoted. Databases in `FG_NON_HELIOS_DBS` — and any database in no failover group at all — stay read-write on production. Failover is scoped to the group, not the account.

---

## 3. Client Redirect (stable connection URL)

A named **Connection** object dedicated to `HELIOS_ANALYTICS_PROD` consumers provides a stable URL that redirects to DR at failover **without application teams changing connection strings**.

| Item | Value |
|---|---|
| Connection name | `HELIOS_CONN` *(confirm)* |
| Connection URL | `MERIDIAN-HELIOS_CONN.snowflakecomputing.com` |
| Scope | **Only `HELIOS_ANALYTICS_PROD` workloads.** Other apps keep using the direct account URL and are unaffected. |

> **Hard prerequisite.** Every pipeline, ETL job, batch process, and app that **writes to** `HELIOS_ANALYTICS_PROD` must be migrated from the raw account URL to the connection URL **before** the first DR test. Client Redirect cannot protect a connection that bypasses it.

---

## 4. DR account placement

A secondary account must exist in a **different region within the same Snowflake organization** (`MERIDIAN`). Meridian has a DR account in **AWS us-west-2** (`MERIDIAN_DR`), satisfying this requirement.

---

## 5. Replication feasibility — the object audit

Before any replication group is created, `HELIOS_ANALYTICS_PROD` must be audited object-by-object. Several object types have replication limits or require manual DR-side setup.

### 5.1 Replication support matrix

| Component | Replicable | Action required |
|---|---|---|
| Permanent & transient tables | ✅ Yes | Standard |
| Dynamic tables | ✅ Yes | First refresh on DR is a full reinitialization |
| External stages | ✅ (definition) | Storage-integration trust must be pre-configured on DR |
| Internal stages | ✅ (with caveats) | Directory table enabled to replicate files; **no file >5 GB** |
| Storage integrations | ✅ (object) | **DR service identity needs IAM role trust policy** on the same Amazon S3 (one-time, AWS IAM) |
| Pipes / Snowpipe | ✅ (object) | **SNS topic + SQS queue + notification integration must be built on DR separately** |
| Streams (standard) | ✅ Yes | Source must be in the same group / database |
| **Streams (append-only)** | ❌ No | **Resolve before the group is created — blocks refresh** |
| Tasks | ✅ Yes | Must have run once; owning roles in `FG_ACCOUNT_LEVEL` |
| External tables | ❌ No | **Skipped silently** — map dependencies |
| Hybrid tables | ❌ No | Not supported |
| Event tables | ❌ No | DMF results/history won't exist on DR |
| **Inbound datashare databases** | ❌ No | **Auto-fulfillment or dual-share required (see §6)** |
| Masking / row-access policies | ✅ Yes | — |
| Tags | ✅ Yes | Cannot be modified on DR side |
| Stored procedures & UDFs | ✅ Yes | If they use external network access, replicate that integration too |

> Verify the audit programmatically with `REPLICATION_GROUP_DANGLING_REFERENCES('FG_HELIOS_DB')` — resolve every `IS_BLOCKING_REFRESH = TRUE` row before the first refresh.

### 5.2 Storage integration nuance

- The storage-integration **object** replicates automatically.
- The DR account uses a **different AWS IAM identity** than production.
- That identity must be granted access (via an **IAM role trust policy**) on the **same** Amazon S3 buckets — a one-time AWS-IAM step before the first drill.
- If the **S3 region itself** fails, external-stage files are unavailable regardless of which Snowflake account is primary. S3 cross-region replication (CRR) is a separate, out-of-scope concern.

## 5.3 BCDR analytics feeding the RPO/RTO targets

RPO/RTO commitments must be grounded in the actual workload. Before locking the refresh cadence, measure each `HELIOS_ANALYTICS_PROD` table's DR weight from storage and replication telemetry:

| Analytic | Feeds | Why it matters |
|---|---|---|
| **Table churn** (fail-safe ÷ active bytes) | **RPO + RTO** | High-churn ("hot") tables put the most data at risk between refreshes (RPO) and cost the most to re-sync/reinitialize on recovery (RTO). A handful of hot tables usually set both numbers. |
| **Database churn ratio** | **RTO** | A high database-wide fail-safe-to-size ratio signals a volatile workload that takes longer to recover. |
| **Transient-table flag** | **RPO** | Transient tables have no fail-safe — changes since the last refresh are unrecoverable. |
| **Replication volume + cost** | **RPO feasibility** | Shows whether a tighter cadence is affordable, or whether churn must be reduced first. |
| **Refresh schedule** | **RPO (definition)** | The cadence on `FG_HELIOS_DB` *is* the worst-case RPO — confirm it matches the business target. |

These feed a simple tiering: **Tier 1** (highest churn + critical downstream like the trade-settlement marts) drives the RPO target and is validated first; **Tier 2** (hot, no critical downstream) is watched for cost; **Tier 3** (cold/static reference data) replicates with the group. A critical, high-churn table that is also **transient or behind a replication gap** is the worst case and must be resolved before the first drill. Full query set in the runbook §1.4.

---

## 6. Inbound data shares — the critical gap

Databases created from an **inbound** data share **cannot be replicated**. Helios consumes market-reference data via inbound shares; each must be resolved by:
1. **Auto-Fulfillment** — provider auto-fulfills the share into us-west-2, or
2. **Dual share** — provider shares to **both** `MERIDIAN_PROD` and `MERIDIAN_DR`.

Track per-provider to closure before Helios can claim full DR coverage.

---

## 7. Impact on other applications during a Helios failover

When `FG_ACCOUNT_LEVEL` + `FG_HELIOS_DB` are promoted to DR:

| Affected | Behavior during the window |
|---|---|
| `HELIOS_ANALYTICS_PROD` on production | Becomes **read-only**. Any process still using the direct production URL to write will **fail**. |
| Account-level objects on production | Become read-only — admin DDL (create/modify users, roles, warehouses) blocked. **Running queries are not impacted.** |
| Other databases on production | **Fully unaffected** — databases not in a promoted group stay read-write. |
| Apps on the connection URL | Redirected to DR; read/write against DR where Helios is now primary. |

> All Helios loads/connections **must** be on the connection URL for this isolation to hold.

---

## 8. Private connectivity + DNS — the manual step that drives RTO

Meridian uses **AWS PrivateLink**, which breaks automatic Client Redirect: every failover requires a **manual DNS change**.

| Stage | Action |
|---|---|
| Pre-config | Both accounts get their own VPC interface endpoint with separate IPs (one-time). |
| Pre-config | Route 53 private-hosted-zone records for the **connection URL and the OCSP URL** point to production's endpoint (one-time). |
| At failover | Network team **manually updates the A records** to the DR endpoint. |
| At failback | Reverse the records back to production. |

**Critical details:**
- **Every** failover needs a manual DNS change — increasing RTO.
- Set DNS **TTL to 60–300 seconds** in advance.
- The **OCSP URL must also be updated**, or certificate validation fails.

```text
meridian-helios_conn.privatelink.snowflakecomputing.com -> vpce-helios-use1   (production, us-east-1)
meridian-helios_conn.privatelink.snowflakecomputing.com -> vpce-helios-usw2   (DR, us-west-2)
```

---

## 9. Prerequisites before the first DR drill

1. Confirm the account is **Business Critical** (required for Failover Groups + Client Redirect).
2. Create the failover groups (`FG_ACCOUNT_LEVEL`, `FG_HELIOS_DB`, `FG_NON_HELIOS_DBS`).
3. Create/name the connection object (`HELIOS_CONN`) and migrate **all** Helios consumers to the connection URL.
4. Complete the object audit (§5); resolve **append-only streams** and **dangling references**; map external/hybrid/event-table dependencies.
5. Grant the DR service identity access (IAM role trust policy) on the shared Amazon S3 buckets.
6. Build the SNS topic + SQS queue + notification integration on DR for any pipes.
7. Resolve **every inbound data share** (auto-fulfillment or dual share) per provider.
8. Pre-create VPC endpoints; pre-stage Route 53 records (connection **and** OCSP URLs); set TTL 60–300s.

---

## 10. Open items

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | Confirm account edition is Business Critical | TBD | ☐ |
| 2 | Confirm connection object name (`HELIOS_CONN`?) | TBD | ☐ |
| 3 | Complete `HELIOS_ANALYTICS_PROD` object inventory + flag append-only streams / external / hybrid / event tables | TBD | ☐ |
| 4 | Enumerate inbound shares; choose auto-fulfillment vs dual share per provider | TBD | ☐ |
| 5 | Migrate all Helios pipelines/apps to the connection URL | TBD | ☐ |
| 6 | Grant DR service identity IAM access on shared S3 buckets | TBD | ☐ |
| 7 | Build DR-side SNS/SQS + notification integration for pipes | TBD | ☐ |
| 8 | Pre-stage VPC endpoints + Route 53 records (connection + OCSP), set TTL | Network team | ☐ |
| 9 | Schedule first non-destructive (clone-and-test) drill | TBD | ☐ |

---

*Worked example derived from the generic Snowflake BCDR best-practice set. Fictional customer; revise as open items close.*
