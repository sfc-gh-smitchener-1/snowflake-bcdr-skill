# Snowflake BCDR — Best-Practice Document Set (Generic)

> **Purpose.** A reusable, customer-agnostic Snowflake business-continuity / disaster-recovery doc set, grounded in Snowflake documentation. It is the canonical source that gets **tailored per customer** (into your project's `CustomerDocs/<CUSTOMER>/`) using the customer's planning docs, meeting recordings, and transcripts.
>
> **Origin.** Generalized from a real Azure DR engagement and reconciled against current Snowflake docs (see references in `DR-Best-Practices.md`). For a fully worked example, see [`sample/`](./sample/).

---

## Documents in this set

| # | Document | Role |
|---|---|---|
| 1 | [`DR-Best-Practices.md`](./DR-Best-Practices.md) | **Reference.** Customer-agnostic recommendations (what / why / risk), cited to Snowflake docs, with a default priority scorecard. Largely reused as-is; re-rank the scorecard per customer. |
| 2 | [`DR-Summary-Template.md`](./DR-Summary-Template.md) | **Template.** The DR design analysis. Copy → fill `<TOKEN>`s → becomes `<CUSTOMER>-DR-Summary.md`. |
| 3 | [`DR-Failover-Failback-Runbook-Template.md`](./DR-Failover-Failback-Runbook-Template.md) | **Template.** The executable runbook (Mode A / Mode B, SQL, DNS step, BCDR analytics, test plan). Copy → fill `<TOKEN>`s → becomes `<CUSTOMER>-DR-Failover-Failback-Runbook.md`. |
| 4 | [`PLACEHOLDERS.md`](./PLACEHOLDERS.md) | **Glossary.** Every `<TOKEN>` used in the templates + a cloud-specific cheat sheet (AWS / Azure / GCP). |
| 5 | [`sample/`](./sample/) | **Worked example.** A fully filled-in set for a fictional AWS customer (Meridian / "Helios") — what the templates look like tailored. Enablement reference for SE / SA / RSA teams. |

---

## How to tailor this to a customer

Use the **[`snowflake-bcdr-tailoring`](../SKILL.md)** skill, or do it manually:

1. Gather the customer's inputs (DR planning doc, architecture notes, meeting recordings/transcripts).
2. Extract the values for every token in [`PLACEHOLDERS.md`](./PLACEHOLDERS.md).
3. Copy the two templates + the best-practices doc into `CustomerDocs/<CUSTOMER>/`, renamed with the customer prefix.
4. Replace every `<TOKEN>`; delete inapplicable sections (e.g., private-connectivity if public); re-rank the scorecard.
5. Add a customer `README.md` index (pattern: [`sample/README.md`](./sample/README.md)).

---

## Design principles (the through-line)

- **Failover is scoped to the group, not the account** — isolate each independently-recoverable workload.
- **Client Redirect only protects connections that flow through the connection object** — migrate 100% of consumers first.
- **The object audit is a gate** — append-only streams, external/hybrid/event tables, inbound shares, and dangling references will silently break DR.
- **RPO/RTO are workload-dependent** — measure churn before committing to numbers.
- **Private connectivity breaks auto-redirect** — the manual DNS+OCSP flip is the dominant, must-rehearse RTO component.
- **Test non-destructively first** (clone-and-test), then end-to-end in a low-traffic window.

---

*Generic reference set. Keep customer-specific values out of these files — tailor copies into `CustomerDocs/<CUSTOMER>/` instead.*
