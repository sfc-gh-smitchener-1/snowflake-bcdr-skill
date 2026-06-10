# Snowflake BCDR — Best-Practice Recommendations (Generic)

> **What this is.** A customer-agnostic set of Snowflake business-continuity / disaster-recovery best practices, grounded in Snowflake documentation. It is the reference from which a per-customer `*-DR-Best-Practices.md` is tailored (see [`README.md`](./README.md) and the [tailoring skill](../SKILL.md)).
>
> **How to read it.** Each recommendation states **what to do**, **why**, and **the risk of not doing it**. Principles are universal; the cloud-specific mechanics (private connectivity, object storage, pipe plumbing) are flagged and resolved per cloud via [`PLACEHOLDERS.md`](./PLACEHOLDERS.md).
>
> **Companion templates.** [`DR-Summary-Template.md`](./DR-Summary-Template.md) · [`DR-Failover-Failback-Runbook-Template.md`](./DR-Failover-Failback-Runbook-Template.md)

---

## 0. Foundations (know these before designing)

| Fact | Implication | Source |
|---|---|---|
| Database **and share** replication is available on **all editions**. | Basic data replication doesn't gate on edition. | [replication-intro] |
| Replication of **account objects** (users/roles/warehouses/policies/integrations), **failover/failback**, and **Client Redirect** require **Business Critical (or higher)**. | The whole "promote DR to read-write + stable URL" pattern is a BC-edition feature. Confirm edition first. | [replication-intro] · [client-redirect] |
| Source and target accounts must be in the **same organization** and in **different regions**. | DR account placement is constrained; you cannot DR within one region. | [client-redirect] |
| Failover happens at the **failover-group** level, not the account level. | You can promote some groups while others stay primary — the basis for blast-radius isolation. | [account-replication-config] |
| A blocking **dangling reference** (an object referenced by a replicated object but not itself replicated) **fails refresh/failover**. | Object grouping must be dependency-complete; verify with `REPLICATION_GROUP_DANGLING_REFERENCES()`. | [dangling-refs] |

---

## 1. Failover-group design

### 1.1 Isolate each independently-recoverable workload into its own group

**Recommendation.** Put each workload that must fail over **independently** into its own failover group. A common, effective layout is three groups:
- `FG_ACCOUNT_LEVEL` — account objects shared by everything (roles, users, warehouses, resource monitors, network policies, integrations).
- `FG_<WORKLOAD>_DB` — the workload's database(s) and dependents.
- `FG_NON_<WORKLOAD>_DBS` — everything else, catalogued but **not** promoted on a workload failover (or simply leave those databases in **no** group).

**Why.** Failover is scoped to the group. Isolating the workload means a drill or real failover promotes only that workload + account objects, leaving unrelated databases read-write on production. This is what makes DR for one tenant on a shared account safe.

**Risk if ignored.** A single co-mingled group turns every drill into an outage for unrelated teams — which kills the willingness to test, and an untested DR plan is not a DR plan.

### 1.2 Make group membership dependency-complete

**Recommendation.** Before the first refresh, run `REPLICATION_GROUP_DANGLING_REFERENCES('<group>')` and resolve every row where `IS_BLOCKING_REFRESH = TRUE`. Where one group depends on another, set the **refresh order** so prerequisites replicate first.

**Why.** A replicated view/task/policy that points at a non-replicated object is a *dangling reference*; a blocking one fails the entire group's refresh and failover, not just that object.

### 1.3 Use SQL, never the GUI, for failover-group changes

**Recommendation.** Make every change (`ADD`/`MOVE` databases, `SET REPLICATION_SCHEDULE`, `PRIMARY`) via `ALTER FAILOVER GROUP`. Add a periodic check that the refresh schedule hasn't drifted.

**Why.** The Snowsight failover-group editor has been observed to silently reset the refresh interval when objects are added through the UI. SQL is authoritative and reviewable.

---

## 2. Client Redirect & connection hygiene

### 2.1 Front every workload with a named Connection object, and migrate 100% of consumers to it *before* the first drill

**Recommendation.** Create a connection object (`<WORKLOAD>_CONN`) and treat migrating **all** writers/readers of `<APP_DB>` from the raw account URL to `<CONNECTION_URL>` as a **hard gate** on the first DR test.

**Why.** Client Redirect only protects connections that flow through the connection object. Anything still on the raw account URL hits a **read-only** primary after failover and fails. (`ALTER CONNECTION <name> ENABLE FAILOVER TO ACCOUNTS <org>.<dr_account>`; promote with `ALTER CONNECTION <name> PRIMARY`.)

**Risk if ignored.** A drill that "passes" while consumers silently bypass redirect gives false confidence; the real outage surfaces the broken connections at the worst time.

### 2.2 Keep a living inventory of connection consumers

**Recommendation.** Maintain a list of every consumer (service account, tool, owning team, connection-string source); re-validate quarterly and after any new integration.

**Why.** You can't migrate or protect connections you don't know about. New pipelines re-introduce the raw-URL gap.

### 2.3 Don't let unrelated apps onto the workload's connection

**Recommendation.** Reserve `<WORKLOAD>_CONN` strictly for the workload; unrelated apps stay on the direct account URL.

**Why.** Routing an unrelated app through the workload connection drags it to DR during a workload-only failover — re-introducing the coupling the design avoids.

---

## 3. The object audit is a gate, not a formality

Snowflake replicates most objects but **not all**, and several need manual DR-side setup. Audit `<APP_DB>` object-by-object before building the group. Items most likely to bite:

### 3.1 Resolve append-only streams before creating the group

**Recommendation.** Enumerate append-only streams in `<APP_DB>` and convert/drop/relocate them before the group is built.

**Why / risk.** They behave as blocking dangling references and fail the whole group's refresh — not just the stream.

### 3.2 Map every dependency on non-replicable / not-supported objects

**Recommendation.** Produce a written dependency map for **external tables**, **hybrid tables**, and **event tables**. For each, document what depends on it and the DR mitigation (rebuild from IaC, accept the gap, or redesign).

**Why / risk.** External tables are **skipped silently** — a downstream view/task fails on DR with no obvious cause. Hybrid/event tables simply don't exist on DR; event-table DMF history won't be there.

### 3.3 Validate stages and file sizes

**Recommendation.**
- Internal stages: enable directory tables if files must replicate; confirm **no file exceeds 5 GB** (oversized files fail refresh).
- External stages: confirm the storage-integration trust is pre-configured on DR (see §4).

**Why / risk.** One oversized internal-stage file can fail the entire refresh; an unconfigured external-stage trust makes the stage unusable on DR.

### 3.4 Ground RPO/RTO in table-churn analytics

**Recommendation.** Before locking the refresh cadence, run the BCDR analytics in the runbook (§1.4) to measure each table's DR weight: rank by **churn** (fail-safe ÷ active bytes — high churn = "hot"), check the **database-wide churn ratio**, flag **transient** tables (no fail-safe), and pull **replication volume/cost**. Let the hot tables set the RPO target and the validation order (Tier 1 first).

**Why.** RPO/RTO are workload-dependent, not arbitrary. Churn analytics reveal which handful of tables dictate how much data is at risk between refreshes (RPO) and how long re-sync/reinitialization takes (RTO), and whether a tighter RPO is affordable or churn must be reduced first.

**Risk if ignored.** A high-churn table silently inflates replication cost and RPO/RTO exposure; a transient or gap-bound critical table is wrong/missing on DR even though "the failover succeeded."

### 3.5 Confirm tasks have run once and have consistent ownership

**Recommendation.** Verify every in-scope task has been resumed/executed at least once and that owning roles are present in `FG_ACCOUNT_LEVEL`.

**Why / risk.** Tasks that never ran, or whose owning role is missing on DR, won't schedule after promotion.

---

## 4. Storage integration & cloud RBAC

### 4.1 Pre-grant the DR service identity — now, not at failover

**Recommendation.** Grant the DR account's cloud identity (`<STORAGE_RBAC_ROLE>`) on the **same** `<OBJECT_STORE>` containers/buckets as production, as a one-time setup during DR build-out.

**Why / risk.** The storage-integration **object** replicates, but the **DR account uses a different cloud identity**. Without the grant, external stages resolve to "access denied" on DR — discovered only when you fail over. (AWS: IAM role trust; Azure: `Storage Blob Data Contributor`; GCP: bucket IAM to the DR service account.)

### 4.2 Treat cloud-storage redundancy as a separate program

**Recommendation.** Decide object-store cross-region redundancy (e.g., S3 CRR, Azure GRS/GZRS/RA-GRS, GCS dual/multi-region) as a distinct workstream owned by the cloud infra team.

**Why.** Snowflake DR protects the Snowflake layer. If the **object-store region** fails, external-stage files are unavailable regardless of which Snowflake account is primary.

### 4.3 Rebuild pipe event plumbing on DR ahead of time

**Recommendation.** For every Snowpipe in scope, pre-build the DR-side `<PIPE_EVENT_PLUMBING>` and document the mapping.

**Why / risk.** Pipe objects replicate, but the cloud event plumbing that feeds them does **not**. Auto-ingest is silently dead on DR until configured.

---

## 5. Inbound data shares (the classic silent gap)

### 5.1 Resolve every inbound share per provider before claiming DR coverage

**Recommendation.** For each inbound share feeding `<APP_DB>`, implement one of: **auto-fulfillment** to the DR region, or a **dual share** (provider shares to both prod and DR accounts). Track each provider to closure.

**Why / risk.** A database created from an inbound share **cannot be replicated**. Any object joining shared data is broken on DR until the share is independently available there — the single most likely "passed the drill, failed the real event" trap.

---

## 6. Private connectivity, DNS & RTO

> Applies when the account uses `<PRIVATE_CONNECTIVITY>`. Private connectivity **breaks automatic Client Redirect**, so DNS is the cutover mechanism on every cloud.

### 6.1 Pre-stage everything; the only failover-time action should be the DNS flip

**Recommendation.** Pre-create both private endpoints (`<PRIMARY_PE>`, `<DR_PE>`) and pre-stage all private DNS records. At failover the network team should only repoint A records.

**Why.** The fewer steps performed under pressure, the lower and more predictable the RTO.

### 6.2 Flip the OCSP URL, not just the connection URL

**Recommendation.** Make "update OCSP URL DNS" an explicit, separate checklist line item.

**Why / risk.** Repointing only the connection URL leaves certificate validation pointing at the old OCSP endpoint → TLS failures that look like a connectivity problem.

### 6.3 Lower DNS TTL to 60–300s in advance

**Recommendation.** Lower TTL on the relevant records well before any drill and keep it there.

**Why.** A long TTL caches the stale IP after the flip, inflating RTO unpredictably. TTL can't help retroactively.

### 6.4 Rehearse and time the network team's DNS step

**Recommendation.** Include the network team in the drill; time the DNS change and record it as a discrete RTO component.

**Why.** The manual DNS change is the largest controllable RTO contributor in a private-connectivity architecture — own it, rehearse it, measure it.

---

## 7. Testing strategy

### 7.1 Start with a non-destructive clone-and-test drill

**Recommendation.** First exercise: zero-copy **clone** the replicated `<APP_DB>` on DR into a throwaway database and validate the clone (runbook §4) instead of promoting.

**Why.** Validates data parity, object presence, and RBAC **without** demoting production or reversing replication — zero risk to the production account and unrelated tenants.

### 7.2 Schedule the destructive end-to-end drill for a low-traffic window

**Recommendation.** Once clone-and-test passes and the connection-URL migration is complete, schedule a full promote/failback (runbook §5–§6) for a low-traffic window, with Snowflake support engaged ahead of time.

**Why.** A full drill is the only way to validate Client Redirect, the manual DNS flip, and the OCSP path end-to-end — but it briefly makes the primary read-only, so timing matters.

### 7.3 Capture a baseline snapshot before and after every drill

**Recommendation.** Run the snapshot queries (runbook §7) on production before and after; diff them — they should be identical.

**Why.** Proves the drill left production unchanged — essential for the trust of any unrelated tenants sharing the account.

### 7.4 Test at least twice a year and after major changes

**Recommendation.** Tabletop quarterly, executable drill semi-annually, plus an ad-hoc drill after any major schema/integration/data-share change.

**Why.** Drift (new pipes, shares, append-only streams) silently erodes DR readiness between tests.

---

## 8. Audit-retention companion (recommended)

DR closes the **availability** gap; it does not satisfy long-horizon audit retention. Native `ACCOUNT_USAGE` is capped at **365 days**, and time-travel/fail-safe is **not** a backup.

**Recommendation.** Pair the DR program with a WORM-compliant immutable backup + extended `ACCOUNT_USAGE` archive (the Temporal Archive pattern). It runs natively in Snowflake (Tasks + Backup Policy) and provides 7+ year retention with `RETENTION LOCK`.

**Why.** Regulated regimes (e.g., financial services) typically require 7+ years of immutable history. Deployed alongside DR, it turns "we can fail over" into "we can fail over **and** prove what happened years later."

> Requires Business Critical or higher (for `RETENTION LOCK`) — the same edition prerequisite as the DR design itself.

---

## 9. Recommendation scorecard (default priorities — re-rank per customer)

| # | Recommendation | Priority | Gate on first drill? |
|---|---|---|---|
| 2.1 | Migrate all workload consumers to the connection URL | 🔴 Critical | **Yes** |
| 3.1 | Resolve append-only streams | 🔴 Critical | **Yes** |
| 5.1 | Resolve all inbound data shares | 🔴 Critical | **Yes** |
| 4.1 | Pre-grant DR service identity cloud RBAC | 🔴 Critical | **Yes** |
| 6.1–6.3 | Pre-stage private connectivity + DNS, OCSP, low TTL | 🔴 Critical | **Yes** (if private connectivity) |
| 1.1 | Strict per-workload group separation | 🟠 High | Yes |
| 1.2 | Resolve blocking dangling references | 🟠 High | Yes |
| 3.2 | Map external/hybrid/event table dependencies | 🟠 High | Yes |
| 3.4 | Ground RPO/RTO in table-churn analytics | 🟠 High | Yes |
| 4.3 | Pre-build DR-side pipe plumbing | 🟠 High | Yes |
| 7.1 | Start with clone-and-test | 🟠 High | — |
| 8 | Deploy WORM audit archive | 🟡 Medium | No |

---

## References (Snowflake documentation)

- [replication-intro] Introduction to business continuity & disaster recovery — https://docs.snowflake.com/en/user-guide/replication-intro
- [account-replication-config] Replicating databases and account objects across multiple accounts — https://docs.snowflake.com/en/user-guide/account-replication-config
- [create-failover-group] CREATE FAILOVER GROUP — https://docs.snowflake.com/en/sql-reference/sql/create-failover-group
- [client-redirect] Redirecting client connections (Client Redirect) — https://docs.snowflake.com/en/user-guide/client-redirect
- [dangling-refs] REPLICATION_GROUP_DANGLING_REFERENCES — https://docs.snowflake.com/en/sql-reference/functions/replication_group_dangling_references

*Generic best-practice reference. Tailor per customer; do not edit this file with customer-specific values.*
