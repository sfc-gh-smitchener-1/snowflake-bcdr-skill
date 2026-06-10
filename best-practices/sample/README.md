# Sample — Worked Example (Meridian Financial / "Helios" on AWS)

> **⚠ Fictional.** "Meridian Financial," the **Helios** workload, account locators, ARNs, and endpoints below are **invented for enablement**. Nothing here is a real customer. Use it as a reference for what a *tailored* BCDR doc set looks like.
>
> **Audience.** SEs, SAs, RSAs, and other Snowflake technical teams.
>
> **What this demonstrates.** The output of running the [`snowflake-bcdr-tailoring`](../../SKILL.md) skill over the generic templates in [`../`](../). It is an **AWS** worked example (the templates were generalized from an Azure engagement) — so you can see how the cloud-specific tokens resolve. The contrast table below maps the AWS and Azure equivalents.

---

## How this example was produced

1. Started from the three generic files one level up (`../DR-Summary-Template.md`, `../DR-Best-Practices.md`, `../DR-Failover-Failback-Runbook-Template.md`).
2. Extracted placeholder values from the (fictional) Meridian DR planning notes — see the values table below.
3. Replaced every `<TOKEN>`, carried realistic schema/table names into the SQL, re-ranked the scorecard, and wrote the README index.
4. Kept the private-connectivity sections (Meridian uses **AWS PrivateLink**), so this is a *complete* example rather than a pruned one.

## Placeholder values used (the extraction table the skill builds)

| Token | Value | Confidence |
|---|---|---|
| `<CUSTOMER>` | Meridian Financial | confirmed |
| `<ORG>` | `MERIDIAN` | confirmed |
| `<PROD_ACCOUNT>` | `MERIDIAN_PROD` | confirmed |
| `<DR_ACCOUNT>` | `MERIDIAN_DR` | confirmed |
| `<WORKLOAD>` | Helios | confirmed |
| `<APP_DB>` | `HELIOS_ANALYTICS_PROD` | confirmed |
| `<CLOUD>` | AWS | confirmed |
| `<PRIMARY_REGION>` | AWS `us-east-1` | confirmed |
| `<DR_REGION>` | AWS `us-west-2` | confirmed |
| `<PRIVATE_CONNECTIVITY>` | AWS PrivateLink | confirmed |
| `<PRIMARY_PE>` | `vpce-helios-use1` | assumed (confirm) |
| `<DR_PE>` | `vpce-helios-usw2` | assumed (confirm) |
| `<OBJECT_STORE>` | Amazon S3 | confirmed |
| `<STORAGE_RBAC_ROLE>` | IAM role trust policy | confirmed |
| `<PIPE_EVENT_PLUMBING>` | SNS topic + SQS queue + notification integration | confirmed |
| `<WORKLOAD>_CONN` | `HELIOS_CONN` | confirmed |
| `<CONNECTION_URL>` | `MERIDIAN-HELIOS_CONN.snowflakecomputing.com` | confirmed |
| `<REFRESH_INTERVAL>` | `10 MINUTE` | assumed (confirm) |
| `<TEST_RUNNER_ROLE>` | `HELIOS_DR_TEST_RUNNER` | confirmed |
| Failover groups | `FG_ACCOUNT_LEVEL` · `FG_HELIOS_DB` · `FG_NON_HELIOS_DBS` | confirmed |

---

## Documents in this sample

| # | Document | Purpose |
|---|---|---|
| 1 | [`Meridian-DR-Summary.md`](./Meridian-DR-Summary.md) | The DR design analysis. |
| 2 | [`Meridian-DR-Best-Practices.md`](./Meridian-DR-Best-Practices.md) | Recommendations + AWS-specific scorecard. |
| 3 | [`Meridian-DR-Failover-Failback-Runbook.md`](./Meridian-DR-Failover-Failback-Runbook.md) | Executable runbook (Mode A / Mode B, SQL, the PrivateLink DNS step, BCDR analytics, test plan). |

## Design at a glance

| Element | Value |
|---|---|
| Cloud / regions | AWS `us-east-1` (prod) ⇄ AWS `us-west-2` (DR) |
| Edition (assumed) | Business Critical — **confirm** |
| Failover groups | `FG_ACCOUNT_LEVEL` · `FG_HELIOS_DB` (`HELIOS_ANALYTICS_PROD`) · `FG_NON_HELIOS_DBS` |
| Promoted on Helios failover | `FG_ACCOUNT_LEVEL` + `FG_HELIOS_DB` only |
| Client Redirect | Connection `HELIOS_CONN` → `MERIDIAN-HELIOS_CONN.snowflakecomputing.com` |
| Private connectivity | AWS PrivateLink — `vpce-helios-use1` (prod) · `vpce-helios-usw2` (DR) |

## Contrast with the Azure example

| Concern | This sample (AWS) | Azure equivalent |
|---|---|---|
| Private connectivity | AWS PrivateLink (VPC endpoints) | Azure Private Link (private endpoints) |
| External-stage store | Amazon S3 | ADLS Gen2 / Blob |
| DR storage RBAC | IAM role trust policy on the bucket | `Storage Blob Data Contributor` on the container |
| Pipe auto-ingest plumbing | SNS topic + SQS queue + notification integration | Event Grid + storage queue + notification integration |

> The DNS + **OCSP** flip and the "manual DNS change is the dominant RTO component" point are identical on both clouds — private connectivity always breaks automatic Client Redirect.

---

*Illustrative artifact. Copy the generic templates in `../`, not this folder, when tailoring a real customer.*
