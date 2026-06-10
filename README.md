# snowflake-bcdr-skill

A [Cortex Code](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code) skill for producing customer-specific Snowflake BCDR (Business Continuity / Disaster Recovery) document sets from the generic best-practice templates.

---

## What this skill does

Given a customer's DR planning inputs (docs, architecture notes, meeting transcripts), this skill:

1. Pulls current Snowflake BCDR documentation to stay up to date with feature releases
2. Extracts all placeholder values (cloud, regions, edition, workload, failover groups, connectivity)
3. Generates three tailored, customer-specific deliverables:
   - `<CUSTOMER>-DR-Summary.md` — design analysis and open items
   - `<CUSTOMER>-DR-Best-Practices.md` — re-ranked recommendations scorecard
   - `<CUSTOMER>-DR-Failover-Failback-Runbook.md` — executable runbook with SQL
4. Prunes inapplicable sections (e.g. private connectivity steps for public-only customers)
5. Verifies no stray tokens remain and cross-references are intact

## Repo contents

```
SKILL.md                                  ← Cortex Code skill entrypoint
best-practices/
  DR-Best-Practices.md                    ← Generic reference (9 sections, cited to Snowflake docs)
  DR-Summary-Template.md                  ← Template → <CUSTOMER>-DR-Summary.md
  DR-Failover-Failback-Runbook-Template.md← Template → <CUSTOMER>-DR-Failover-Failback-Runbook.md
  PLACEHOLDERS.md                         ← Every <TOKEN> + cloud cheat sheet (AWS/Azure/GCP)
  sample/                                 ← Fully worked example (fictional AWS customer "Meridian")
```

---

## Install

```bash
# Install from GitHub (replace with your org/repo once published)
cortex skill add <github-org>/snowflake-bcdr-skill

# Or from a local clone
cortex skill add /path/to/snowflake-bcdr-skill
```

After install, verify with:
```bash
cortex skill list
```

## Usage

In a Cortex Code session, provide your customer inputs and say something like:

> "Tailor the BCDR templates for Acme Corp — planning doc is attached"

> "Build a DR runbook for Globex, Azure East US 2 → Central US, private link, Business Critical"

> "Update the Initech DR set with the notes from today's call"

Triggers that activate the skill: `BCDR`, `disaster recovery`, `DR runbook`, `failover group`, `client redirect`, `RPO/RTO`, `tailor DR docs`, `backup`, `replication`, `business continuity`.

---

## Updating the templates

The `best-practices/` files are the **generic source of truth** — keep them customer-agnostic.
Customer-specific output goes into your project's `CustomerDocs/<CUSTOMER>/` directory, never back here.

To update the templates:
1. Edit the relevant file in `best-practices/`
2. Update `PLACEHOLDERS.md` if new tokens are introduced
3. Update `best-practices/sample/` to reflect the change (keep the worked example current)
4. Bump the skill if publishing a new version

## Contributing

RSA / Product team members: PRs welcome for:
- New best-practice sections as Snowflake adds BCDR capabilities
- Additional cloud-specific cheat sheet entries in `PLACEHOLDERS.md`
- New sample worked examples (additional clouds, multi-workload patterns)

---

*Grounded in [Snowflake BCDR documentation](https://docs.snowflake.com/en/user-guide/replication-intro). The skill refreshes docs on every run to stay current.*
