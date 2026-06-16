# Plymouth Rock — Snowflake BCDR Best-Practice Recommendations

> **What this is.** Plymouth Rock-specific adaptation of the Snowflake BCDR best practices. Each recommendation states **what to do**, **why**, and **the risk of not doing it**, grounded in Plymouth's confirmed environment (AWS, Business Critical, NoVA ↔ Ohio, HVR ingest, Tableau BI).
>
> **Companion documents.** `PlymouthRock-DR-Summary.md` · `PlymouthRock-DR-Failover-Failback-Runbook.md`

---

## 0. Foundations for Plymouth

| Fact | Plymouth implication |
|---|---|
| Database and share replication is available on all editions. | Plymouth is on Business Critical — no edition gate for core replication. |
| Replication of **account objects**, **failover/failback**, and **Client Redirect** require **Business Critical or higher**. | ✅ Plymouth is Business Critical (converted from Enterprise — Musawar, meeting 29:08). Full failover-group + Client Redirect capability is available. |
| Source and target accounts must be in the **same organization** and **different regions**. | Plymouth NoVA (us-east-1) ↔ Ohio (us-east-2) satisfies this. Both must be in the same Snowflake org. Confirm org name (Open Item 1 in Summary). |
| Failover happens at the **failover-group** level, not the account level. | Plymouth can promote `FG_PLYMOUTH_DB` independently without affecting databases in other groups. |
| A blocking **dangling reference** fails refresh/failover for the entire group. | Plymouth must run `REPLICATION_GROUP_DANGLING_REFERENCES('FG_PLYMOUTH_DB')` and resolve every `IS_BLOCKING_REFRESH = TRUE` row before the first refresh. |

> **Note (doc refresh — BCR-1555, 2024_02 bundle).** Dangling reference errors during refresh are now **aggregated**: all blocking references surface simultaneously, and the refresh fails cleanly before any secondary objects are updated. Plymouth can use one pass to identify and fix all blocking references at once — no more cascading failures one-at-a-time.

---

## 1. Failover-group design

### 1.1 Use three groups; Plymouth's layout

**Recommendation.** Plymouth's group layout:
- `FG_ACCOUNT_LEVEL` — users, roles, warehouses, resource monitors, network policies, integrations (account-wide).
- `FG_PLYMOUTH_DB` — `PLYMOUTH_PROD` + `PLYMOUTH_ANALYTICS` and all dependent objects.
- `FG_NON_PLYMOUTH_DBS` — any additional databases not in the primary DR scope (catalogued; not promoted on a Plymouth failover).

**Why.** Failover is scoped to the promoted groups. `FG_NON_PLYMOUTH_DBS` stays on NoVA during any Plymouth drill or real failover.

**Plymouth-specific caveat.** `FG_ACCOUNT_LEVEL` replicates account-level objects account-wide. When promoted to Ohio, admin DDL on NoVA (CREATE/ALTER/DROP roles, users, warehouses) is frozen for the duration. Running queries and DML against read-write databases are unaffected. Plymouth's Rajan Rajanagan should confirm this is acceptable before the Mode A drill.

**Risk if ignored.** A single co-mingled group turns every drill into a potential disruption for all workloads and makes it impossible to stage the Mode A drill safely.

### 1.2 Make FG_PLYMOUTH_DB membership dependency-complete

**Recommendation.** Before the first refresh, run:
```sql
SELECT * FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_DANGLING_REFERENCES('FG_PLYMOUTH_DB'));
```
Resolve every row where `IS_BLOCKING_REFRESH = TRUE`. If `FG_ACCOUNT_LEVEL` and `FG_PLYMOUTH_DB` refresh in sequence, set refresh order so `FG_ACCOUNT_LEVEL` completes first.

**Why.** A replicated view, task, or policy in `FG_PLYMOUTH_DB` that references a non-replicated object (e.g., a role or integration not yet in `FG_ACCOUNT_LEVEL`) blocks the entire group's refresh and failover.

**Plymouth risk.** Hybrid tables in PLYMOUTH_PROD are not replicated (§3.2). Any view, task, or policy that joins a hybrid table will appear as a dangling reference or return wrong results on Ohio. Map these before the first drill.

### 1.3 Use SQL, never the GUI, for failover-group changes — Plymouth-specific known bug

**Recommendation.** Make every change (`ADD DATABASE`, `SET REPLICATION_SCHEDULE`, `PRIMARY`) via `ALTER FAILOVER GROUP`. Add a monitoring check that verifies the refresh schedule has not drifted.

**Plymouth-specific.** The Snowsight failover-group editor has a **confirmed display bug** (Pulugundla, meeting 39:21; Tom Smith acknowledged): after `ALTER FAILOVER GROUP ... SET REPLICATION_SCHEDULE = '5 MINUTE'`, the GUI still shows 10 minutes. The actual replication runs on 5 minutes. However, **adding a database via the GUI resets the interval to 10 minutes**. Plymouth's action: add a CI/policy check that verifies the schedule and alerts on drift.

```sql
-- Verify actual refresh schedule (authoritative — ignore GUI)
SHOW FAILOVER GROUPS;
-- Check REPLICATION_SCHEDULE column = '5 MINUTE' for FG_PLYMOUTH_DB
```

---

## 2. Client Redirect & connection hygiene

### 2.1 Migrate HVR and all consumers to the connection URL before the first drill

**Recommendation.** Every writer and reader of PLYMOUTH_PROD / PLYMOUTH_ANALYTICS — **especially HVR** — must use the connection URL (`snowflake.plymouth.<your-domain>`) as a **hard gate** on the first DR test.

**Plymouth context.** HVR is Plymouth's primary ingest tool, writing from Northern Virginia into Snowflake. Musawar confirmed (meeting 50:26) that HVR's connection target must be the connection URL, not the raw NoVA account URL. Tableau (Robert Gay) and any other BI tools must also be migrated. Any consumer still on the raw account URL hits a **read-only** secondary after failover and fails.

**Why.** Client Redirect only protects connections that flow through the connection object. Anything bypassing it is invisible to the redirect mechanism.

**Risk if ignored.** A Mode B test may appear to pass while HVR and Tableau silently use the raw URL; the real outage surfaces those broken connections at the worst time.

### 2.2 Maintain a living inventory of connection consumers

**Recommendation.** Pulugundla and Robert Gay should maintain a list of every consumer (HVR, Tableau, service accounts, batch jobs, dashboards); re-validate before each drill and after any new integration.

**Why.** New pipelines introduced as Plymouth decommissions the legacy DW may re-introduce raw-URL connections.

### 2.3 Note on PrivateLink and the CNAME

If Plymouth's `snowflake.plymouth.<your-domain>` resolves to a **PrivateLink endpoint** (`*.privatelink.snowflakecomputing.com`), the Client Redirect command (`ALTER CONNECTION PLYMOUTH_CONN PRIMARY`) does **not** automatically redirect traffic. The network team must manually update the CNAME to point to Ohio's endpoint. See §6 below and the runbook §5.1.7.

---

## 3. The object audit is a gate, not a formality

### 3.1 Resolve append-only streams before the first refresh

**Recommendation.** Run `SHOW STREAMS IN DATABASE PLYMOUTH_PROD` and `SHOW STREAMS IN DATABASE PLYMOUTH_ANALYTICS`. Any stream with `MODE = APPEND_ONLY` must be converted, dropped, or relocated before `FG_PLYMOUTH_DB` is created or refreshed.

**Why / risk.** Append-only streams are blocking dangling references — they fail the entire group's refresh, not just the stream itself.

### 3.2 Map Plymouth's hybrid tables and other non-replicable objects

**Recommendation.** Produce a written dependency map for Plymouth's **hybrid tables** — confirmed to exist (Pulugundla, meeting 1:59). For each hybrid table, document: which views, tasks, or stored procedures join it, and the DR mitigation (e.g., run without that data, accept the gap, rebuild from IaC on Ohio for the test).

**Plymouth-confirmed non-replicable objects:**
- **Hybrid tables** — remain on NoVA; do NOT appear on Ohio after failover. Not dropped from NoVA.
- **External tables** — skipped silently. Any downstream view on Ohio that references one will error on query.
- **Streamlit apps** — now replicate via BCR-2316 (see §3.5). Account-level dependencies must still be verified on Ohio.
- **Event tables** — DMF history won't exist on Ohio.

**Risk if ignored.** External tables are skipped silently — a downstream view fails on Ohio with no obvious cause. Hybrid-table gaps are visible only when someone queries dependent objects after failover.

### 3.3 Validate S3 stages and file sizes

**Recommendation.**
- **Internal stages:** enable directory tables if files must replicate; confirm no file exceeds **5 GB** (oversized files fail the entire group refresh).
- **External stages (S3):** confirm the storage-integration IAM trust is pre-configured on the Ohio DR account (the Ohio IAM identity is a different ARN from NoVA's).

**Why / risk.** One oversized internal-stage file fails the refresh for the whole group. An unconfigured S3 trust makes external stages return "access denied" on Ohio, discovered only at failover.

### 3.4 Ground the 5-minute RPO in table-churn analytics

**Recommendation.** Before locking Plymouth's 5-minute refresh cadence, run the BCDR analytics (runbook §1.4): rank PLYMOUTH_PROD and PLYMOUTH_ANALYTICS tables by **churn** (fail-safe ÷ active bytes). The hot tables set the achievable RPO and RTO. Confirm that the 5-minute interval is both sufficient (hot tables don't change faster than Snowflake can replicate them) and affordable (replication credits are within budget).

**Plymouth context.** Plymouth has tables with up to **15-day time-travel retention** (Pulugundla, meeting 15:08) — these are likely high-value reference tables. Separately, Plymouth currently relies on time travel as a backup substitute (Jill Weigand, meeting 18:46) — this is a gap being addressed by the Temporal Archive recommendation (§8).

**Risk if ignored.** A 5-minute RPO commitment that outpaces what high-churn tables can deliver gives false confidence; a tighter interval that inflates replication credits surprises finance.

### 3.5 Verify Streamlit replication via BCR-2316

> **Note (doc refresh — BCR-2316, 2026_04 bundle).** As of the April 2026 behavior change bundle, Streamlit-in-Snowflake objects replicate automatically with their containing database. Plymouth previously identified Streamlit replication as a gap (Snowflake version 10.5 did not support it). This gap is now closed, provided the 2026_04 bundle is enabled.

**Recommendation.** Before the Mode B test:
1. Run `SHOW PARAMETERS LIKE 'ENABLE_STREAMLIT_REPLICATION' IN ACCOUNT` on both NoVA and Ohio — expected `TRUE`.
2. Inventory all SiS apps in PLYMOUTH_PROD / PLYMOUTH_ANALYTICS and map their account-level dependencies (Compute Pools, External Access Integrations, Secrets, owning roles).
3. Verify each dependency exists on Ohio with the same name. Warehouses and roles are already covered by `FG_ACCOUNT_LEVEL`. EAIs and Secrets must be recreated on Ohio manually.

Full verification SQL in the runbook §11.2.

### 3.6 Confirm tasks have run once and have consistent ownership

**Recommendation.** Verify every in-scope task in PLYMOUTH_PROD / PLYMOUTH_ANALYTICS has been resumed and executed at least once, and that the owning role is present in `FG_ACCOUNT_LEVEL`.

**Plymouth context.** Tom Smith confirmed (meeting 40:43): tasks in a *resumed* state replicate with that state and automatically schedule on whichever account is primary. Plymouth's validation step (runbook §9.7) must confirm tasks schedule correctly on Ohio.

---

## 4. Storage integration & AWS RBAC

### 4.1 Pre-grant the Ohio DR IAM identity now, not at failover

**Recommendation.** Identify the Ohio DR account's IAM user/role ARN (different from the NoVA IAM ARN) and add it to the **IAM role trust policy** on every S3 bucket used by PLYMOUTH_PROD / PLYMOUTH_ANALYTICS — a one-time AWS IAM step during DR build-out.

**Why / risk.** The storage-integration **object** replicates, but the Ohio DR account uses a **different IAM identity**. Without the trust policy update on S3, external stages show "access denied" on Ohio — only discovered at failover, during the worst possible moment.

**AWS mechanics:** Snowflake's Ohio account will have a different `STORAGE_AWS_IAM_USER_ARN` and `STORAGE_AWS_EXTERNAL_ID`. Run `DESC INTEGRATION <storage_integration_name>` on the Ohio account after the group is created to get the exact values, then update the S3 bucket trust policies.

### 4.2 Treat S3 redundancy as a separate program

**Recommendation.** Decide whether to enable **S3 Cross-Region Replication (CRR)** from us-east-1 to us-east-2 as a distinct workstream owned by Plymouth's cloud infra team.

**Why.** Snowflake DR protects the Snowflake layer. If the S3 bucket region itself fails, external-stage files are unavailable regardless of which Snowflake account is primary.

### 4.3 Snowpipe plumbing (confirm if applicable)

Plymouth's primary ingest is **HVR** — not Snowpipe. If any Snowpipe objects exist in PLYMOUTH_PROD / PLYMOUTH_ANALYTICS, Plymouth must pre-build **SNS/SQS event plumbing** on the Ohio DR account. The Snowpipe object replicates; the event subscription does not.

**Action:** Run `SHOW PIPES IN DATABASE PLYMOUTH_PROD` and `SHOW PIPES IN DATABASE PLYMOUTH_ANALYTICS`. If any exist, build Ohio-side SNS/SQS plumbing before the first drill.

---

## 5. Inbound data shares

### 5.1 Resolve every inbound share before claiming DR coverage

**Recommendation.** Audit all inbound shares feeding PLYMOUTH_PROD / PLYMOUTH_ANALYTICS. For each, implement auto-fulfillment to Ohio (us-east-2) or a dual share (provider shares to both NoVA and Ohio accounts). Track per-provider to closure.

**Why / risk.** A database created from an inbound share cannot be replicated. Any object joining shared data returns wrong/empty results after failover even though the failover "succeeded" — the most common "passed the drill, failed the real event" trap.

---

## 6. Private connectivity, DNS & RTO

> *Applies if Plymouth's `snowflake.plymouth.<your-domain>` resolves to a PrivateLink endpoint. Confirm before the first drill.*

### 6.1 Pre-stage everything; the only failover-time action should be the CNAME flip

**Recommendation.** Pre-create both PrivateLink endpoints (NoVA and Ohio) and pre-stage the DNS CNAME records. At failover, the network team repoints two CNAME records (connection URL + OCSP URL) — that is the entire DNS action.

**Why.** The fewer steps performed under pressure, the lower and more predictable the RTO. Plymouth's target RTO is 15 minutes; the DNS CNAME change is the dominant manual step.

### 6.2 Flip the OCSP URL, not just the connection URL

**Recommendation.** Make "update OCSP URL CNAME" a separate, explicit checklist line item — not an afterthought.

**Why / risk.** Repointing only the connection URL leaves TLS certificate validation pointing at the old OCSP endpoint → TLS failures that look like a connectivity problem, not a DNS problem. Plymouth's runbook §5.1.7 lists both as required.

### 6.3 Lower DNS TTL to 60–300s in advance

**Recommendation.** Lower the TTL on the CNAME records well before any drill.

**Why.** A long TTL caches the stale IP after the CNAME flip, inflating RTO unpredictably. TTL reduction cannot help retroactively. Once lowered, keep it there.

### 6.4 Include the network team in the drill; time the DNS step

**Recommendation.** The network team (whoever owns `snowflake.plymouth.<your-domain>`) must be on the bridge during both Mode B and Mode A drills. Time the CNAME change as a discrete RTO measurement.

---

## 7. Testing strategy

### 7.1 Plymouth's May 2026 test: Mode B (non-destructive clone-and-test)

**Recommendation.** Plymouth's immediate test should be **Mode B**: zero-copy clone `PLYMOUTH_PROD` and `PLYMOUTH_ANALYTICS` into throwaway test databases on Ohio and validate against the clones. Production stays primary throughout; Virginia is never overwritten.

**Why.** Validates data parity, object presence, and RBAC without demoting production, reversing replication, or disrupting HVR or Tableau. This is the correct first test given that Plymouth wants to confirm DR readiness before decommissioning the legacy DW, with zero risk to production.

**Plymouth's non-destructive requirement (confirmed, meeting 45:15 — Musawar).** Mode B explicitly supports "discard all changes on Ohio and come back to Virginia as if nothing happened." All writes during the test go to the Ohio clones, not the actual secondary. Virginia is never touched.

### 7.2 Schedule Mode A after the legacy DW is retired

**Recommendation.** Once Mode B passes and the legacy DW is decommissioned (making HVR the sole source of truth), schedule a Mode A end-to-end drill (real failover + failback) in a low-traffic window (Saturday or Sunday). Engage Snowflake AAA Ninja support ≥7 days in advance.

**Why.** Mode A validates Client Redirect, the DNS CNAME flip, and the full OCSP/TLS path end-to-end. It briefly makes production read-only, so timing and support coverage matter.

### 7.3 Capture a baseline snapshot before and after every drill

**Recommendation.** Run the baseline snapshot queries (runbook §7) on NoVA **before** and **after** the Mode B test; diff them — they should be identical.

**Why.** Proves the Mode B test left Virginia unchanged — essential for Plymouth's non-destructive test requirement and for building confidence in the DR plan before decommissioning the legacy DW.

### 7.4 Test at least twice a year after the first drill

**Recommendation.** After the first Mode A drill, run a tabletop quarterly and a live drill semi-annually; add an ad-hoc drill after any major schema, integration, or share change.

**Plymouth context.** Plymouth has a June 2026 DR test window in view. Once Mode A is established, the recurring cadence should be built into Plymouth's audit calendar.

---

## 8. Audit-retention companion (Temporal Archive — Jill Weigand's requirement)

Plymouth is currently relying on **time travel as a backup substitute** (Jill Weigand, meeting 18:46) — a documented gap. Native `ACCOUNT_USAGE` data is capped at 365 days, and time travel / fail-safe is **not** a backup.

**Recommendation.** Pair the DR program with a WORM-compliant immutable backup + extended `ACCOUNT_USAGE` archive (**Temporal Archive pattern**). It runs natively in Snowflake (Tasks + Snapshot Policy) and provides 7+ year retention with `RETENTION LOCK`.

**Plymouth specifics (from runbook §10):**
- Plymouth is on Business Critical — `RETENTION LOCK` is available. ✅
- Cortex Analyst and Cortex Agents availability should be confirmed (Pulugundla, Open Item 10-A in runbook).
- Jill Weigand and Musawar own the compliance and backup strategy workstream.
- Recommended path: **Cortex Code Skill deployment** (Option 2 in runbook §10.7).
- Deploy at T+30d post-Mode-B test; reduce time-travel retention on large tables (15 days → 2–7 days) at T+45d once Temporal Archive is live.

> Requires Business Critical edition — Plymouth already satisfies this.

---

## 9. Recommendation scorecard — Plymouth-ranked priorities

Re-ranked for Plymouth's specific environment and open gaps.

| # | Recommendation | Plymouth priority | Gate on first drill? |
|---|---|---|---|
| 2.1 | Migrate HVR + Tableau + all consumers to the connection URL | 🔴 Critical | **Yes** |
| 3.1 | Resolve append-only streams in PLYMOUTH_PROD / PLYMOUTH_ANALYTICS | 🔴 Critical | **Yes** |
| 3.2 | Map hybrid-table dependencies; accept or mitigate the gap | 🔴 Critical | **Yes** |
| 4.1 | Pre-grant Ohio DR IAM identity on all S3 buckets | 🔴 Critical | **Yes** |
| 1.3 | Always use SQL (not GUI) for failover-group changes; alert on schedule drift | 🔴 Critical | **Yes** |
| 6.1–6.3 | *(If PrivateLink)* Pre-stage DNS CNAMEs + OCSP; set TTL 60–300s | 🔴 Critical | **Yes** (if PrivateLink) |
| 1.2 | Resolve all blocking dangling references in FG_PLYMOUTH_DB | 🟠 High | Yes |
| 3.4 | Run BCDR churn analytics; confirm 5-min RPO is achievable and affordable | 🟠 High | Yes |
| 3.5 | Verify BCR-2316 Streamlit replication + account-level dependencies on Ohio | 🟠 High | Yes |
| 3.6 | Confirm tasks have run once; owning roles in FG_ACCOUNT_LEVEL | 🟠 High | Yes |
| 5.1 | Resolve all inbound data shares | 🟠 High | Yes |
| 7.1 | Run Mode B clone-and-test drill first | 🟠 High | — |
| 4.3 | Confirm Snowpipe objects; if found, build SNS/SQS plumbing on Ohio | 🟡 Medium | Only if Snowpipe exists |
| 8 | Deploy Temporal Archive (WORM backup + ACCOUNT_USAGE archive) | 🟡 Medium | No |

---

## References

- [replication-intro] Introduction to business continuity & disaster recovery — https://docs.snowflake.com/en/user-guide/replication-intro
- [account-replication-config] Replicating databases and account objects — https://docs.snowflake.com/en/user-guide/account-replication-config
- [create-failover-group] CREATE FAILOVER GROUP — https://docs.snowflake.com/en/sql-reference/sql/create-failover-group
- [client-redirect] Client Redirect — https://docs.snowflake.com/en/user-guide/client-redirect
- [dangling-refs] REPLICATION_GROUP_DANGLING_REFERENCES — https://docs.snowflake.com/en/sql-reference/functions/replication_group_dangling_references
- [bcr-2316] BCR-2316 Streamlit replication enabled by default — https://docs.snowflake.com/en/release-notes/bcr-bundles/2026_04/bcr-2316
- [bcr-1555] BCR-1555 Dangling reference error aggregation — https://docs.snowflake.com/en/release-notes/bcr-bundles/2024_02/bcr-1555

*Plymouth Rock-specific best-practice document. Do not edit the generic templates with these values.*
