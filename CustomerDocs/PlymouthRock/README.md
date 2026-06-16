# Plymouth Rock — Snowflake BCDR Document Set

## Purpose & constraint

Tailored Snowflake Business Continuity / Disaster Recovery documentation for **Plymouth Rock**, prepared by Snowflake Team (Steve Mitchener) following the May 14, 2026 working session. Plymouth is preparing to retire its legacy data warehouse; the DR plan must be validated before that gate event.

**Central constraint:** Plymouth's May 2026 DR test is **non-destructive (Mode B)**. Virginia must return to primary state "as if nothing happened" — Ohio changes are discarded at test end. Mode A (full failover/failback) is planned after the legacy DW is retired.

## Source material

| File | Description |
|---|---|
| `Plymouth Snowflake DR Failover _ Failback Runbook.docx` | Primary Plymouth runbook (detailed, with open items tracker) |
| `Snowflake_Plymouth_BC_DR_Runbook_v1.0.docx` | BC/DR enterprise summary — RPO/RTO targets, phases |
| `Snowflake DR_ Failover & Fallback — Data Flow Diagrams & Response.docx` | Diagrams (binary — embedded in the .docx) |
| `Untitled document.docx` | Meeting transcript — May 14, 2026, 52m working session |

## Documents in this set

| Document | Purpose |
|---|---|
| `PlymouthRock-DR-Summary.md` | One-page design summary — groups, connection URL, gaps, prerequisites, open items |
| `PlymouthRock-DR-Best-Practices.md` | Snowflake BCDR best practices tailored to Plymouth's environment and ranked by Plymouth's real gaps |
| `PlymouthRock-DR-Failover-Failback-Runbook.md` | Full operational runbook — Mode B (May 2026 test) + Mode A (future real-DR) with SQL and step-by-step checklists |

## Design at a glance

| Item | Value |
|---|---|
| **Cloud** | AWS |
| **Primary** | us-east-1 (Northern Virginia) |
| **DR** | us-east-2 (Ohio) |
| **Edition** | Business Critical (confirmed) |
| **RPO target** | 5 minutes |
| **RTO target** | 15 minutes |
| **Refresh interval** | 5 MINUTE (set via SQL — GUI shows 10 min, known bug) |
| **Primary ingest** | HVR (writing from Northern Virginia) |
| **BI** | Tableau (Robert Gay) + other consumers |
| **Primary databases** | PLYMOUTH_PROD, PLYMOUTH_ANALYTICS |
| **Connectivity** | `snowflake.plymouth.<your-domain>` *(confirm: public or PrivateLink)* |
| **Test mode (May 2026)** | Mode B — non-destructive clone-and-test |
| **Real-DR mode** | Mode A — scheduled after legacy DW retirement |

## Critical gaps to close before the first drill

1. **Connection URL migration** — HVR and Tableau must use the connection URL, not the raw NoVA account URL. (Best-practices §2.1, Runbook §3.1)
2. **Hybrid table dependency map** — Plymouth has hybrid tables; they will not exist on Ohio. Every downstream object that joins them must be mapped and a mitigation accepted. (Best-practices §3.2)
3. **Append-only stream audit** — any append-only stream in PLYMOUTH_PROD / PLYMOUTH_ANALYTICS blocks all group refresh. Must be zero. (Best-practices §3.1)
4. **Ohio IAM trust policy on S3** — the Ohio DR IAM identity has a different ARN from NoVA. S3 bucket trust policies must be updated before the first drill. (Best-practices §4.1)
5. **BCR-2316 Streamlit dependency map** — SiS replication is now enabled; account-level dependencies (EAIs, Secrets, owning roles) must be verified on Ohio. (Runbook §11.2)
6. *(If PrivateLink)* **DNS CNAME pre-staging** — connection URL and OCSP URL CNAMEs must be pre-staged; TTL lowered to 60–300s. (Best-practices §6)

## Key people

| Name | Role |
|---|---|
| Musawar Nadeem | Test Lead |
| Pulugundla Narasimham | Test Engineer (primary) |
| Rajan Rajanagan | Architecture / Approvals |
| Robert Gay | Tableau / downstream consumers |
| Jill Weigand | Operations / Backups (Temporal Archive owner) |
| Paul Lobello | Performance sign-off |
| Steve Mitchener (Snowflake) | Runbook author, account team |
| Tom Smith (Snowflake) | Product liaison (GUI bug, BCR-2316) |

---

*Living document set. Revise after each test cycle and as open items close. Do not add Plymouth-specific values to the generic templates in `best-practices/`.*
