# Meridian Financial — DR Best-Practice Recommendations

> **⚠ Fictional enablement example.** Meridian Financial / "Helios" is invented. See [`README.md`](./README.md).
>
> **Audience.** Helios platform engineering + Meridian account administrators.
> **Companion documents.** [`Meridian-DR-Summary.md`](./Meridian-DR-Summary.md) · [`Meridian-DR-Failover-Failback-Runbook.md`](./Meridian-DR-Failover-Failback-Runbook.md)
>
> Each recommendation states **what to do**, **why**, and **the risk of not doing it**. Snowflake-correctness is cited in the generic reference (`../DR-Best-Practices.md`).

---

## 1. Failover-group design

### 1.1 Keep the three-group separation strict

**Recommendation.** Maintain exactly three failover groups with non-overlapping membership: `FG_ACCOUNT_LEVEL`, `FG_HELIOS_DB`, `FG_NON_HELIOS_DBS`. Never add `HELIOS_ANALYTICS_PROD` to a group that also contains unrelated production databases.

**Why.** The value of this design is **blast-radius isolation** — Helios can fail over without forcing read-only state onto applications that never asked for DR.

**Risk if ignored.** A single co-mingled group makes every Helios drill an outage for unrelated teams, which kills the willingness to test — and an untested DR plan is not a DR plan.

### 1.2 Make group membership dependency-complete

**Recommendation.** Before the first refresh, run `REPLICATION_GROUP_DANGLING_REFERENCES('FG_HELIOS_DB')` and resolve every row where `IS_BLOCKING_REFRESH = TRUE`. Where one group depends on another, set the refresh order so prerequisites replicate first.

**Why.** A replicated view/task/policy pointing at a non-replicated object is a *dangling reference*; a blocking one fails the entire group's refresh and failover — not just that object.

### 1.3 Use SQL, not the GUI, for failover-group changes

**Recommendation.** Make every change (`ADD`/`MOVE` databases, `SET REPLICATION_SCHEDULE`, `PRIMARY`) via `ALTER FAILOVER GROUP`. Add a periodic check that the refresh schedule has not drifted.

**Why.** The Snowsight failover-group editor has a known habit of silently resetting the refresh interval when an object is added through the UI. SQL is authoritative.

---

## 2. Client Redirect & connection hygiene

### 2.1 Migrate 100% of Helios writers to the connection URL *before* the first drill

**Recommendation.** Treat migrating all `HELIOS_ANALYTICS_PROD` pipelines, ETL jobs, batch processes, BI tools, and apps to `MERIDIAN-HELIOS_CONN.snowflakecomputing.com` as a **hard gate** on the first DR test.

**Why.** Client Redirect only protects connections that flow through the connection object. Anything still on the raw Meridian account URL hits a **read-only** `HELIOS_ANALYTICS_PROD` during failover and fails.

**Risk if ignored.** A drill that "passes" while half the writers silently bypass redirect gives false confidence — the real outage surfaces the broken connections at the worst time.

### 2.2 Inventory connection consumers and keep the list current

**Recommendation.** Maintain a living inventory of every consumer of `HELIOS_ANALYTICS_PROD` (service account, tool, owning team, connection-string source). Re-validate quarterly and after any new integration.

**Why.** You cannot migrate or protect connections you do not know about. New pipelines re-introduce the raw-URL gap.

### 2.3 Don't let non-Helios apps onto the Helios connection URL

**Recommendation.** Reserve `HELIOS_CONN` strictly for Helios. Non-Helios applications stay on the direct Meridian account URL.

**Why.** Routing a non-Helios app through `HELIOS_CONN` drags it to DR during a Helios-only failover — re-introducing the coupling the design avoids.

---

## 3. The object audit is a gate, not a formality

### 3.1 Resolve append-only streams before creating the replication group

**Recommendation.** Enumerate all append-only streams in `HELIOS_ANALYTICS_PROD` and convert/drop/relocate them before the group is built.

**Why / risk.** Append-only streams are not replicable and behave as blocking dangling references — they **block the refresh of the entire group**, not just the stream.

### 3.2 Map every dependency on non-replicable object types

**Recommendation.** Produce a written dependency map for **external tables**, **hybrid tables**, and **event tables**. For each, document what depends on it and the DR mitigation (rebuild from IaC, accept gap, or redesign).

**Why / risk.** External tables are **skipped silently** — a downstream view or task fails on DR with no obvious cause. Hybrid and event tables simply do not exist on DR.

### 3.3 Validate stages and file sizes

**Recommendation.**
- Internal stages: confirm directory tables are enabled if files must replicate, and **no file exceeds 5 GB**.
- External (S3) stages: confirm the storage-integration trust is pre-configured on DR.

**Why / risk.** A single oversized internal-stage file can fail the entire refresh; an unconfigured external-stage trust makes the stage unusable on DR.

### 3.4 Ground the RPO/RTO targets in table-churn analytics

**Recommendation.** Before locking the failover-group refresh schedule, run the BCDR analytics in runbook §1.4 to measure each `HELIOS_ANALYTICS_PROD` table's DR weight: rank by **churn** (fail-safe ÷ active bytes — high churn = "hot"), check the **database-wide churn ratio**, flag **transient** tables (no fail-safe), and pull **replication volume/cost**. Let the hot tables (likely the trade-settlement and position marts) set the RPO target and the validation order (Tier 1 first).

**Why.** RPO and RTO are workload-dependent, not arbitrary. Churn analytics tell you which handful of tables dictate how much data is at risk between refreshes (RPO) and how long re-sync/reinitialization takes (RTO), and whether a tighter RPO is affordable or churn must be reduced first.

**Risk if ignored.** A high-churn table silently inflates replication cost and RPO/RTO exposure; a transient or gap-bound critical table is wrong or missing on DR after failover even though "the failover succeeded."

### 3.5 Confirm tasks have run once and have consistent ownership

**Recommendation.** Verify every in-scope task has been resumed/executed at least once and that owning roles are present in `FG_ACCOUNT_LEVEL`.

**Why / risk.** Tasks that never ran, or whose owning role is missing on DR, won't schedule after promotion.

---

## 4. Storage integration & AWS IAM

### 4.1 Pre-grant the DR service identity — do it now, not at failover

**Recommendation.** Grant the DR account's AWS IAM identity access (via the bucket/role trust policy) on the **same** Amazon S3 buckets as production, as a one-time setup during DR build-out.

**Why / risk.** The storage-integration object replicates, but the **DR account uses a different IAM role ARN**. Without the trust-policy update, external stages resolve to "access denied" on DR — discovered only when you actually fail over.

### 4.2 Treat S3 cross-region redundancy as a separate program

**Recommendation.** Decide S3 cross-region replication (CRR) for the underlying buckets as a distinct workstream owned by the AWS infrastructure team.

**Why.** Snowflake DR protects the Snowflake layer. If the **S3 region** itself fails, external-stage files are unavailable regardless of which Snowflake account is primary.

### 4.3 Rebuild pipe event plumbing on DR ahead of time

**Recommendation.** For every Snowpipe in scope, pre-build the DR-side **SNS topic + SQS queue + notification integration**. Document the mapping.

**Why / risk.** Pipe objects replicate, but the AWS event plumbing that feeds them does **not**. Auto-ingest is silently dead on DR until configured.

---

## 5. Inbound data shares (the critical gap)

### 5.1 Resolve every inbound share per provider before claiming DR coverage

**Recommendation.** For each inbound data share feeding `HELIOS_ANALYTICS_PROD` (market-reference data), implement one of:
1. **Auto-Fulfillment** to us-west-2, or
2. **Dual share** — provider shares to both `MERIDIAN_PROD` and `MERIDIAN_DR`.

Track each provider to closure.

**Why / risk.** A database created from an inbound share **cannot be replicated**. Any Helios object joining shared data is broken on DR until the share is independently available there — the single most likely "passed the drill, failed the real event" trap.

---

## 6. PrivateLink, DNS & RTO

### 6.1 Pre-stage everything; the only failover-time action should be the DNS flip

**Recommendation.** Pre-create both VPC interface endpoints (`vpce-helios-use1` for production, `vpce-helios-usw2` for DR) and pre-stage all Route 53 private-hosted-zone records. At failover the network team should only repoint the A records.

**Why.** PrivateLink breaks automatic Client Redirect, so DNS is the cutover mechanism. The fewer steps under pressure, the lower and more predictable the RTO.

### 6.2 Update the OCSP URL, not just the connection URL

**Recommendation.** Make "update OCSP URL DNS" an explicit, separate checklist line item.

**Why / risk.** Repointing only the connection URL leaves certificate validation pointing at the old OCSP endpoint → TLS failures that look like a connectivity problem.

### 6.3 Set DNS TTL to 60–300 seconds in advance

**Recommendation.** Lower the TTL on the relevant records to 60–300s well before any drill, and keep it there.

**Why.** A long TTL caches the stale (production) IP after the flip, inflating RTO unpredictably. TTL can't help retroactively.

### 6.4 Rehearse and time the network team's DNS step

**Recommendation.** Include the AWS network team in the drill; time the DNS change and record it as a discrete RTO component.

**Why.** The manual DNS change is the largest controllable RTO contributor in this architecture — own it, rehearse it, measure it.

---

## 7. Testing strategy

### 7.1 Start with a non-destructive clone-and-test drill

**Recommendation.** For the first exercise, zero-copy **clone** the replicated `HELIOS_ANALYTICS_PROD` on DR into a throwaway database and validate the clone (runbook §4) instead of promoting.

**Why.** Validates data parity, object presence, and RBAC **without** demoting production or reversing replication — zero risk to the production account and unrelated tenants.

### 7.2 Schedule the destructive end-to-end drill for a low-traffic window

**Recommendation.** Once clone-and-test passes and the connection-URL migration is complete, schedule a full promote/failback (runbook §5–§6) for a low-traffic window (e.g., a weekend outside market hours), with Snowflake support engaged ahead of time.

**Why.** A full drill is the only way to validate Client Redirect, the manual DNS flip, and the OCSP path end-to-end — but it briefly makes production read-only, so timing matters.

### 7.3 Capture a baseline snapshot before and after every drill

**Recommendation.** Run the snapshot queries (runbook §7) on production before and after; diff them — they should be identical.

**Why.** Proves the drill left production unchanged — essential for the trust of the non-Helios tenants sharing the account.

### 7.4 Test at least twice a year and after major changes

**Recommendation.** Tabletop quarterly, executable drill semi-annually, plus an ad-hoc drill after any major schema/integration/data-share change.

**Why.** Drift (new pipes, shares, append-only streams) silently erodes DR readiness between tests.

---

## 8. Audit-retention companion (recommended)

DR closes the **availability** gap; it does not satisfy long-horizon audit retention. Native `ACCOUNT_USAGE` is capped at **365 days**, and time-travel/fail-safe is **not** a backup.

**Recommendation.** Pair the Helios DR program with a **WORM-compliant immutable backup + extended `ACCOUNT_USAGE` archive** (the Temporal Archive pattern). It runs natively in Snowflake (Tasks + Backup Policy) and provides 7+ year retention with `RETENTION LOCK`.

**Why.** Financial-services audit regimes typically require 7+ years of immutable history. Deployed alongside DR, it turns "we can fail over" into "we can fail over **and** prove what happened years later."

> Requires Business Critical or higher (for `RETENTION LOCK`) — the same edition prerequisite as the DR design itself.

---

## 9. Recommendation scorecard

| # | Recommendation | Priority | Gate on first drill? |
|---|---|---|---|
| 2.1 | Migrate all Helios writers to the connection URL | 🔴 Critical | **Yes** |
| 3.1 | Resolve append-only streams | 🔴 Critical | **Yes** |
| 5.1 | Resolve all inbound data shares | 🔴 Critical | **Yes** |
| 4.1 | Pre-grant DR service identity AWS IAM access on S3 | 🔴 Critical | **Yes** |
| 6.1–6.3 | Pre-stage VPC endpoints + Route 53, OCSP, low TTL | 🔴 Critical | **Yes** |
| 1.1 | Strict three-group separation | 🟠 High | Yes |
| 1.2 | Resolve blocking dangling references | 🟠 High | Yes |
| 3.2 | Map external/hybrid/event table dependencies | 🟠 High | Yes |
| 3.4 | Ground RPO/RTO in table-churn analytics | 🟠 High | Yes |
| 4.3 | Pre-build DR-side SNS/SQS pipe plumbing | 🟠 High | Yes |
| 7.1 | Start with clone-and-test | 🟠 High | — |
| 8 | Deploy WORM audit archive | 🟡 Medium | No |

---

*Worked example derived from the generic Snowflake BCDR best-practice set (`../DR-Best-Practices.md`). Fictional customer; living document.*
