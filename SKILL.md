---
name: snowflake-bcdr-tailoring
description: >-
  Tailor the generic Snowflake BCDR best-practice doc set into a customer-specific
  DR summary, best-practices, and failover/failback runbook, using the customer's
  inputs (DR planning docs, architecture notes, meeting recordings/transcripts).
  Use when the user asks to create or update a customer DR/BCDR doc set, tailor the
  BCDR templates, build a failover runbook for a customer, or turn DR planning notes
  into deliverables. Triggers: BCDR, disaster recovery, DR runbook, failover group,
  client redirect, RPO/RTO, tailor DR docs, customer DR plan, backup, replication,
  business continuity.
---

# Snowflake BCDR Customer Tailoring

Produce a customer-specific Snowflake DR document set by tailoring the generic
templates bundled with this skill. The generic set is the source of truth for
*structure and Snowflake-correct content*; the customer inputs supply the *values and
which sections apply*.

> **File paths.** All reference files are co-located with this skill. Use the
> `Base directory:` path shown when the skill loads to resolve the paths below.
> Customer output files go into your **working project directory**, not the skill directory.

---

## Step 0 — Refresh Snowflake documentation (run on EVERY invocation)

Before reading any local files or customer inputs, pull current Snowflake docs to catch
feature changes since the templates were last updated. Run all four queries; scan the
results for anything that contradicts, extends, or supersedes statements in
`best-practices/DR-Best-Practices.md`.

```bash
cortex search docs "business continuity disaster recovery replication intro"
cortex search docs "failover group create alter refresh schedule"
cortex search docs "client redirect connection failover"
cortex search docs "replication group dangling references blocking"
```

**After scanning, note any deltas:**
- New objects/features now supported for replication (previously unsupported types)
- Changed edition requirements (e.g., a feature moved from Business Critical to Enterprise)
- New or changed limits (e.g., the >5 GB internal-stage file restriction, refresh-interval minimums)
- New SQL syntax for `CREATE/ALTER FAILOVER GROUP`, `ALTER CONNECTION`, or `ALTER REPLICATION GROUP`
- New backup or point-in-time restore capabilities

If a delta contradicts a best-practice in `DR-Best-Practices.md`, flag it explicitly in
the tailored output with a `> **Note (doc refresh):**` callout, and update the relevant
section. Snowflake docs are authoritative over the local templates.

---

## Source files (read after Step 0)

Paths are relative to this skill's base directory:

| File | Use |
|---|---|
| `best-practices/PLACEHOLDERS.md` | Token list + cloud cheat sheet — your extraction checklist |
| `best-practices/DR-Best-Practices.md` | Reference doc — mostly reused; re-rank scorecard |
| `best-practices/DR-Summary-Template.md` | Copy → `<CUSTOMER>-DR-Summary.md` in project dir |
| `best-practices/DR-Failover-Failback-Runbook-Template.md` | Copy → `<CUSTOMER>-DR-Failover-Failback-Runbook.md` in project dir |
| `best-practices/sample/` | Fully filled-in worked example (fictional AWS customer "Meridian") — reference for tone and depth |
| `sql/` | Reference SQL scripts for failover group setup, connection failover, and cleanup |

---

## Workflow

Copy this checklist and track progress:

```
- [ ] Step 0: Refresh Snowflake docs + note any deltas
- [ ] Step 1: Collect & read all customer inputs
- [ ] Step 2: Extract every placeholder value (PLACEHOLDERS.md)
- [ ] Step 3: Confirm gaps with the user (only genuinely unknown, material ones)
- [ ] Step 4: Generate the three docs into CustomerDocs/<CUSTOMER>/ in the project
- [ ] Step 5: Prune inapplicable sections + re-rank the scorecard
- [ ] Step 6: Write the customer README index
- [ ] Step 7: Verify (tokens, cross-refs, doc-delta callouts, lint)
```

### Step 1 — Collect & read customer inputs

Accept any of: a DR planning doc, architecture diagrams/notes, an existing runbook, and
**meeting recordings or transcripts**.

- **Text inputs** (`.md`, `.docx`, `.pdf`, `.txt`): read directly. For `.docx`/`.pdf`, prefer a `_converted/*.md` if one exists; otherwise extract text.
- **Meeting recordings**: you cannot listen to audio/video. If given a media file, ask for (or locate) a **transcript**. Read it and mine it for: confirmed decisions, account/region/edition facts, named objects, owners, and open questions raised.
- Treat the customer's own wording for design intent and constraints as authoritative; do not override it with generic template defaults.

### Step 2 — Extract placeholder values

Build a values table covering **every** token in `best-practices/PLACEHOLDERS.md`. For each token record: value, source (which doc/line or "meeting"), and confidence (`confirmed` / `assumed` / `unknown`).

Key extraction targets:
- **Edition** — Business Critical? (gates Failover Groups + Client Redirect). If unstated, mark assumed-and-confirm.
- **Cloud + regions** — sets the cloud-specific tokens (private connectivity, object store, RBAC role, pipe plumbing) via the cheat sheet in `PLACEHOLDERS.md`.
- **Workload + database** — `<WORKLOAD>`, `<APP_DB>`, and failover-group names derived from them.
- **Shared-account constraint** — one tenant on a shared account (the single-tenant-on-shared-account pattern in `best-practices/sample/`), or full-account DR? Decides whether the `FG_NON_<WORKLOAD>_DBS` separation and §7 "impact on other apps" sections stay.
- **Private vs public connectivity** — decides whether DNS/OCSP steps stay or are deleted.
- **Replication gaps in use** — inbound shares, append-only streams, external/hybrid/event tables actually present.

### Step 3 — Confirm gaps with the user

Only ask about values that are genuinely unknown **and** material (edition, cloud, shared-vs-full-account, connectivity type). For non-material unknowns, insert a clearly-marked `<value> (confirm)` placeholder and add an Open Items row rather than blocking. Use the `AskQuestion` tool for the material decisions.

### Step 4 — Generate the three docs

Create `CustomerDocs/<CUSTOMER>/` in the **project working directory** and write:
1. `<CUSTOMER>-DR-Summary.md` — from `best-practices/DR-Summary-Template.md`
2. `<CUSTOMER>-DR-Best-Practices.md` — from `best-practices/DR-Best-Practices.md`
3. `<CUSTOMER>-DR-Failover-Failback-Runbook.md` — from `best-practices/DR-Failover-Failback-Runbook-Template.md`

Replace **every** `<TOKEN>` with the extracted value. Keep section numbers stable (the
docs cross-reference each other by number). Carry the customer's real object/schema names
into the SQL examples where known; otherwise leave a `<schema>`/`<task>` placeholder.

If Step 0 surfaced a doc delta that affects this customer's design, incorporate the
correction and annotate with a `> **Note (doc refresh):**` callout.

### Step 5 — Prune & re-rank

- **Public connectivity** → delete private-connectivity content: summary §8, runbook §1.4 connectivity note, §5.1.7, §6.8, constraints 11.1–11.3, and tests 9.10–9.11.
- **Full-account DR (not single-tenant)** → simplify the three-group story; adjust §7 / §1.1 accordingly.
- **No inbound shares / pipes / external stages** → remove or mark N/A the corresponding rows, gaps, and tests.
- **Re-rank the scorecard** (best-practices §9) so the customer's real critical gaps are at the top; keep "gate on first drill" flags honest.

### Step 6 — Customer README index

Write `CustomerDocs/<CUSTOMER>/README.md` following the pattern in `best-practices/sample/README.md`:
purpose + constraint, source, "Documents in this set" table, "Design at a glance" table,
and the "critical gaps to close before the first drill" list.

### Step 7 — Verify

- **No stray tokens**: grep new folder for `<[A-Z_]+>`; every hit must be an intentional `(confirm)` or in-SQL `<schema>`-style placeholder.
- **Cross-references resolve**: §1.4 analytics, §1.3/§5/§8 references, and the best-practices "runbook §1.4" pointer all point at sections that still exist after pruning.
- **Edition/cloud consistency**: same edition, cloud, regions, and connectivity choice across all three docs and the README.
- **Doc-delta callouts present**: if Step 0 found deltas, each has a `> **Note (doc refresh):**` callout in the relevant section.
- Run markdown lint and fix issues introduced.

---

## Guardrails

- **Snowflake docs are authoritative over the local templates.** If Step 0 reveals a conflict, current docs win. Flag the discrepancy rather than silently patching it.
- **Don't invent Snowflake behavior.** If docs search returns nothing on a specific claim, mark it `(verify with Snowflake docs)`.
- **Customer values live only in the project's `CustomerDocs/<CUSTOMER>/`.** Never write customer-specific values back into the skill's `best-practices/` files — those stay generic.
- **Preserve verbatim customer requirements.** If the user supplies exact wording for a constraint or RPO/RTO target, use it as-is.
- **Living documents.** Keep the "revise after each drill / as open items close" footers.

---

## Updating an existing customer set

Treat new inputs (e.g., a follow-up meeting transcript) as a diff: update only the
values/sections that changed, close or add Open Items, note what changed. Do not
regenerate from scratch and lose prior customizations.

Re-run Step 0 on updates too — a doc refresh is cheap and keeps the set current with
any Snowflake releases since the last edit.
