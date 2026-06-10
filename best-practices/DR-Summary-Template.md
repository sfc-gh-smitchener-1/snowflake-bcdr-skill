# <CUSTOMER> — Disaster Recovery Planning Summary (Template)

> **How to use.** Copy this file into the customer's folder, rename to `<CUSTOMER>-DR-Summary.md`, and replace every `<TOKEN>` per [`PLACEHOLDERS.md`](./PLACEHOLDERS.md). Delete sections that don't apply (e.g., the private-connectivity section if the customer uses public connectivity). Keep the structure — the runbook and best-practices cross-reference these section numbers.
>
> **Scope.** DR for the `<WORKLOAD>` workload (`<APP_DB>`) on the `<CUSTOMER>` Snowflake account, on **`<CLOUD>`**, with a DR account in **`<DR_REGION>`**. Defining constraint: *other applications on the same production account do not have DR plans and must not be disrupted* when `<WORKLOAD>` fails over. *(Adjust if the customer is failing over the whole account.)*
>
> **Edition.** Failover Groups, **Connection** objects, and **Client Redirect** are **Business Critical Edition** features — confirm the account edition as a prerequisite.
>
> **Companion documents.** `<CUSTOMER>-DR-Best-Practices.md` · `<CUSTOMER>-DR-Failover-Failback-Runbook.md`

---

## 1. The problem this design solves

`<WORKLOAD>` needs regional DR, but it is a tenant on a **shared production account** alongside other applications that have **no DR requirement**. A single-failover-group design would drag those unrelated workloads into read-only state on every failover or drill.

The plan isolates `<WORKLOAD>` into its own failover group so it can be promoted to the DR account **independently**, without touching the other databases on production.

---

## 2. Proposed approach — independent failover groups

| # | Failover Group | Contents | Purpose |
|---|---|---|---|
| 1 | **`FG_ACCOUNT_LEVEL`** | Users, roles, warehouses, resource monitors, network policies, integrations | Shared account infrastructure; fails over independently of the workload database. |
| 2 | **`FG_<WORKLOAD>_DB`** | `<APP_DB>` and dependent objects | The workload. Scoped exclusively to `<WORKLOAD>` — promotable to DR **without affecting other production workloads**. |
| 3 | **`FG_NON_<WORKLOAD>_DBS`** | All other production databases not in scope for full DR | Catalogued/replicable but **out of the `<WORKLOAD>` failover path**. |

> **Why separate groups.** When `<WORKLOAD>` fails over, only `FG_ACCOUNT_LEVEL` + `FG_<WORKLOAD>_DB` are promoted. Databases in `FG_NON_<WORKLOAD>_DBS` — and any database in no failover group at all — stay read-write on production. Failover is scoped to the group, not the account.

---

## 3. Client Redirect (stable connection URL)

A named **Connection** object dedicated to `<APP_DB>` consumers provides a stable URL that redirects to DR at failover **without application teams changing connection strings**.

| Item | Value |
|---|---|
| Connection name | `<WORKLOAD>_CONN` *(confirm)* |
| Connection URL | `<CONNECTION_URL>` |
| Scope | **Only `<APP_DB>` workloads.** Other apps keep using the direct account URL and are unaffected. |

> **Hard prerequisite.** Every pipeline, ETL job, batch process, and app that **writes to** `<APP_DB>` must be migrated from the raw account URL to the connection URL **before** the first DR test. Client Redirect cannot protect a connection that bypasses it.

---

## 4. DR account placement

A secondary account must exist in a **different region within the same Snowflake organization** (`<ORG>`). `<CUSTOMER>` has a DR account in **`<DR_REGION>`** (`<DR_ACCOUNT>`), satisfying this requirement.

---

## 5. Replication feasibility — the object audit

Before any replication group is created, `<APP_DB>` must be audited object-by-object. Several object types have replication limits or require manual DR-side setup.

### 5.1 Replication support matrix

| Component | Replicable | Action required |
|---|---|---|
| Permanent & transient tables | ✅ Yes | Standard |
| Dynamic tables | ✅ Yes | First refresh on DR is a full reinitialization |
| External stages | ✅ (definition) | Storage-integration trust must be pre-configured on DR |
| Internal stages | ✅ (with caveats) | Directory table enabled to replicate files; **no file >5 GB** |
| Storage integrations | ✅ (object) | **DR service identity needs `<STORAGE_RBAC_ROLE>`** on the same `<OBJECT_STORE>` (one-time, cloud IAM) |
| Pipes / Snowpipe | ✅ (object) | **`<PIPE_EVENT_PLUMBING>` must be built on DR separately** |
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

> Verify the audit programmatically with `REPLICATION_GROUP_DANGLING_REFERENCES('FG_<WORKLOAD>_DB')` — resolve every `IS_BLOCKING_REFRESH = TRUE` row before the first refresh.

### 5.2 Storage integration nuance

- The storage-integration **object** replicates automatically.
- The DR account uses a **different cloud identity** than production.
- That identity must be granted `<STORAGE_RBAC_ROLE>` on the **same** `<OBJECT_STORE>` containers/buckets — a one-time cloud-IAM step before the first drill.
- If the **object-store region itself** fails, external-stage files are unavailable regardless of which Snowflake account is primary. Cloud-side storage redundancy is a separate, out-of-scope concern.

## 5.3 BCDR analytics feeding the RPO/RTO targets

RPO/RTO commitments must be grounded in the actual workload. Before locking the refresh cadence, measure each `<APP_DB>` table's DR weight from storage and replication telemetry:

| Analytic | Feeds | Why it matters |
|---|---|---|
| **Table churn** (fail-safe ÷ active bytes) | **RPO + RTO** | High-churn ("hot") tables put the most data at risk between refreshes (RPO) and cost the most to re-sync/reinitialize on recovery (RTO). A handful of hot tables usually set both numbers. |
| **Database churn ratio** | **RTO** | A high database-wide fail-safe-to-size ratio signals a volatile workload that takes longer to recover. |
| **Transient-table flag** | **RPO** | Transient tables have no fail-safe — changes since the last refresh are unrecoverable. |
| **Replication volume + cost** | **RPO feasibility** | Shows whether a tighter cadence is affordable, or whether churn must be reduced first. |
| **Refresh schedule** | **RPO (definition)** | The cadence on `FG_<WORKLOAD>_DB` *is* the worst-case RPO — confirm it matches the business target. |

These feed a simple tiering: **Tier 1** (highest churn + critical downstream) drives the RPO target and is validated first; **Tier 2** (hot, no critical downstream) is watched for cost; **Tier 3** (cold/static) replicates with the group. A critical, high-churn table that is also **transient or behind a replication gap** is the worst case and must be resolved before the first drill. Full query set in the runbook §1.4.

---

## 6. Inbound data shares — the critical gap

Databases created from an **inbound** data share **cannot be replicated**. Each inbound share into `<APP_DB>` must be resolved by:
1. **Auto-Fulfillment** — provider auto-fulfills the share into the DR region, or
2. **Dual share** — provider shares to **both** `<PROD_ACCOUNT>` and `<DR_ACCOUNT>`.

Track per-provider to closure before `<WORKLOAD>` can claim full DR coverage.

---

## 7. Impact on other applications during a `<WORKLOAD>` failover

When `FG_ACCOUNT_LEVEL` + `FG_<WORKLOAD>_DB` are promoted to DR:

| Affected | Behavior during the window |
|---|---|
| `<APP_DB>` on production | Becomes **read-only**. Any process still using the direct production URL to write will **fail**. |
| Account-level objects on production | Become read-only — admin DDL (create/modify users, roles, warehouses) blocked. **Running queries are not impacted.** |
| Other databases on production | **Fully unaffected** — databases not in a promoted group stay read-write. |
| Apps on the connection URL | Redirected to DR; read/write against DR where `<WORKLOAD>` is now primary. |

> All `<WORKLOAD>` loads/connections **must** be on the connection URL for this isolation to hold.

---

## 8. Private connectivity + DNS — the manual step that drives RTO

*(Include only if the customer uses `<PRIVATE_CONNECTIVITY>`.)* Private connectivity breaks automatic Client Redirect: every failover requires a **manual DNS change**.

| Stage | Action |
|---|---|
| Pre-config | Both accounts get their own private endpoint with separate IPs (one-time). |
| Pre-config | DNS records for the **connection URL and the OCSP URL** point to production's endpoint (one-time). |
| At failover | Network team **manually updates DNS A records** to the DR endpoint. |
| At failback | Reverse the DNS records back to production. |

**Critical details:**
- **Every** failover needs a manual DNS change — increasing RTO.
- Set DNS **TTL to 60–300 seconds** in advance.
- The **OCSP URL must also be updated**, or certificate validation fails.

```text
<connection-url>.privatelink.snowflakecomputing.com -> <PRIMARY_PE>   (production, <PRIMARY_REGION>)
<connection-url>.privatelink.snowflakecomputing.com -> <DR_PE>        (DR, <DR_REGION>)
```

---

## 9. Prerequisites before the first DR drill

1. Confirm the account is **Business Critical** (required for Failover Groups + Client Redirect).
2. Create the failover groups (`FG_ACCOUNT_LEVEL`, `FG_<WORKLOAD>_DB`, `FG_NON_<WORKLOAD>_DBS`).
3. Create/name the connection object (`<WORKLOAD>_CONN`) and migrate **all** `<WORKLOAD>` consumers to the connection URL.
4. Complete the object audit (§5); resolve **append-only streams** and **dangling references**; map external/hybrid/event-table dependencies.
5. Grant the DR service identity `<STORAGE_RBAC_ROLE>` on the shared `<OBJECT_STORE>`.
6. Build `<PIPE_EVENT_PLUMBING>` on DR for any pipes.
7. Resolve **every inbound data share** (auto-fulfillment or dual share) per provider.
8. *(If private connectivity)* Pre-create private endpoints; pre-stage DNS (connection **and** OCSP URLs); set TTL 60–300s.

---

## 10. Open items

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | Confirm account edition is Business Critical | TBD | ☐ |
| 2 | Confirm connection object name (`<WORKLOAD>_CONN`?) | TBD | ☐ |
| 3 | Complete `<APP_DB>` object inventory + flag append-only streams / external / hybrid / event tables | TBD | ☐ |
| 4 | Enumerate inbound shares; choose auto-fulfillment vs dual share per provider | TBD | ☐ |
| 5 | Migrate all `<WORKLOAD>` pipelines/apps to the connection URL | TBD | ☐ |
| 6 | Grant DR service identity cloud RBAC on shared storage | TBD | ☐ |
| 7 | Build DR-side pipe plumbing | TBD | ☐ |
| 8 | Pre-stage private endpoints + DNS (connection + OCSP), set TTL | TBD | ☐ |
| 9 | Schedule first non-destructive (clone-and-test) drill | TBD | ☐ |

---

*Template derived from the generic Snowflake BCDR best-practice set. Replace all `<TOKEN>` values and revise as open items close.*
