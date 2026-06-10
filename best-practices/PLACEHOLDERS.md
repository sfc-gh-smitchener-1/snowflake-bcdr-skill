# Placeholder Glossary

Every template in this folder uses the tokens below. When tailoring the set to a
customer, replace **every** occurrence across all three documents with the
customer's real value (or a clearly-marked `(confirm)` value when unknown).
Keep the token names identical across documents so cross-references line up.

## Identity & accounts

| Token | Meaning | Example |
|---|---|---|
| `<CUSTOMER>` | Customer / company display name | `Meridian Financial` |
| `<ORG>` | Snowflake organization name | `MERIDIAN` |
| `<PROD_ACCOUNT>` | Primary (production) account locator | `MERIDIAN_PROD` |
| `<DR_ACCOUNT>` | DR (secondary) account locator | `MERIDIAN_DR` |

## Workload being protected

| Token | Meaning | Example |
|---|---|---|
| `<WORKLOAD>` | Name of the tenant/app/workload getting DR | `Helios` |
| `<APP_DB>` | Primary database for the workload | `HELIOS_ANALYTICS_PROD` |
| `<APP_DB>_DRTEST` | Throwaway clone name for non-destructive testing | `HELIOS_ANALYTICS_PROD_DRTEST` |
| `<TEST_RUNNER_ROLE>` | Role used to validate the clone / DR | `HELIOS_DR_TEST_RUNNER` |

## Failover groups & connection

| Token | Meaning | Example |
|---|---|---|
| `FG_ACCOUNT_LEVEL` | Failover group for account objects (roles, users, warehouses, …) | `FG_ACCOUNT_LEVEL` |
| `FG_<WORKLOAD>_DB` | Failover group holding `<APP_DB>` and its dependents | `FG_HELIOS_DB` |
| `FG_NON_<WORKLOAD>_DBS` | Failover group cataloguing the other databases (not promoted on a workload failover) | `FG_NON_HELIOS_DBS` |
| `<WORKLOAD>_CONN` | Client Redirect connection object | `HELIOS_CONN` |
| `<CONNECTION_URL>` | Stable connection URL exposed to consumers | `MERIDIAN-HELIOS_CONN.snowflakecomputing.com` |
| `<REFRESH_INTERVAL>` | Failover-group replication schedule (worst-case RPO) | `10 MINUTE` |

## Cloud & networking

| Token | Meaning | Example |
|---|---|---|
| `<CLOUD>` | Cloud provider | `Azure` / `AWS` / `GCP` |
| `<PRIMARY_REGION>` | Region of the production account | `Azure East US 2` |
| `<DR_REGION>` | Region of the DR account (must differ from primary) | `Azure Central US` |
| `<PRIVATE_CONNECTIVITY>` | Private connectivity product (cloud-specific) | `Azure Private Link` |
| `<PRIMARY_PE>` | Private endpoint / connectivity object on production | `EASTSNFPEP1` |
| `<DR_PE>` | Private endpoint / connectivity object on DR | `CENTRALSNFPEP1` |
| `<OBJECT_STORE>` | External-stage object store | `ADLS Gen2 / Blob` |
| `<STORAGE_RBAC_ROLE>` | RBAC needed by the DR service identity on the store | `Storage Blob Data Contributor` |
| `<PIPE_EVENT_PLUMBING>` | Cloud auto-ingest plumbing for Snowpipe | `Event Grid + storage queue + notification integration` |

## Cloud-specific cheat sheet (fill `<...>` above from the matching column)

| Concern | AWS | Azure | GCP |
|---|---|---|---|
| `<PRIVATE_CONNECTIVITY>` | AWS PrivateLink | Azure Private Link | Google Cloud Private Service Connect |
| `<OBJECT_STORE>` | Amazon S3 | ADLS Gen2 / Blob | Google Cloud Storage |
| `<STORAGE_RBAC_ROLE>` | IAM role trust policy on the bucket | `Storage Blob Data Contributor` on the container | IAM grant to the DR service account on the bucket |
| `<PIPE_EVENT_PLUMBING>` | SNS/SQS event notifications | Event Grid + storage queue + notification integration | Pub/Sub subscription |
| DR identity type | DR account's IAM user/role (different ARN) | DR account's Azure service principal (different SP) | DR account's GCP service account |

> **Rule of thumb.** Private connectivity (any cloud) **breaks automatic Client Redirect** — a manual DNS change is always required at failover, and the **OCSP URL must be flipped along with the connection URL** or TLS validation fails.
