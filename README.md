# DKP Flink Terraform

Terraform/Terragrunt infrastructure for managing Confluent Cloud Flink resources via GitOps.

## Overview

This repository provisions:

- **Flink Compute Pools** — region-scoped CFU compute capacity that runs Flink statements
- **Flink SQL Statements** — continuous streaming queries (INSERT INTO / CREATE TABLE AS SELECT)

State lives in Azure Storage (`azurerm` backend). Confluent admin + Flink API credentials live in Azure Key Vault and are pulled at plan/apply time — secrets never enter Terraform state, GitHub secrets, or CI environment variables.

## Project structure

```
dkp-flink-terraform/
├── README.md                           ← you are here
├── .gitignore
├── docs/
│   ├── dkp-onboarding.md               ← step-by-step setup guide for new deployments
│   ├── scoped-operations.md            ← partial-scope ops (destroy only statements, etc.)
│   └── ci-cd-vs-local-cli.md           ← architectural rationale: when to use CI vs CLI
├── .github/
│   ├── README.md                       ← workflow + secrets/vars reference
│   └── workflows/terraform-flink.yml   ← plan / apply / destroy across dev/uat/prd
├── tools/
│   ├── install.sh                      ← pinned terraform + terragrunt installer
│   ├── versions.env                    ← pinned tool versions
│   └── bootstrap-azure-state.sh        ← one-time Azure state SA + AKV + SP setup
└── terraform/
    ├── live/
    │   ├── root.hcl                    ← shared backend + provider config
    │   ├── dev/
    │   │   ├── flink-config.json       ← env-specific config (org_id, env_id, sa_id, statements)
    │   │   ├── compute-pool/terragrunt.hcl
    │   │   └── statements/terragrunt.hcl
    │   ├── uat/
    │   │   ├── flink-config.json
    │   │   ├── compute-pool/terragrunt.hcl
    │   │   └── statements/terragrunt.hcl
    │   └── prd/
    │       ├── flink-config.json
    │       ├── compute-pool/terragrunt.hcl
    │       └── statements/terragrunt.hcl
    └── modules/
        ├── confluent-flink-compute-pool/
        └── confluent-flink-statements/
```

Each environment is split into two Terragrunt stacks: `compute-pool/` and `statements/`. The statements stack declares a `dependency` on the compute-pool stack and pulls the pool's `id` + `flink_rest_endpoint` outputs, so `terragrunt run-all apply` provisions in the correct order.

## Quick links

- **New to this repo?** Start with [`docs/dkp-onboarding.md`](docs/dkp-onboarding.md) for the end-to-end setup walkthrough.
- **Doing partial ops** (destroy just statements, stop one statement)? See [`docs/scoped-operations.md`](docs/scoped-operations.md).
- **Wondering when to use CI vs local CLI?** See [`docs/ci-cd-vs-local-cli.md`](docs/ci-cd-vs-local-cli.md).
- **Setting up GitHub secrets/vars or modifying the workflow?** See [`.github/README.md`](.github/README.md).

## Prerequisites

- Azure subscription with: Contributor on the resource group hosting the state SA + AKV, and permission to register Entra ID app registrations.
- Confluent Cloud organization with at least one environment per stage (dev / uat / prd) and a Kafka cluster in each.
- A Confluent service account per stage (or one combined) with the RBAC listed below.
- GitHub repo with the secrets and variables listed in [`.github/README.md`](.github/README.md).
- For local invocation: [Terraform](https://www.terraform.io/downloads) and [Terragrunt](https://terragrunt.gruntwork.io/) — versions pinned in `tools/versions.env`. CI installs them automatically via `tools/install.sh`.

## Configuration

Each environment's settings live in `terraform/live/<env>/flink-config.json`:

```json
{
  "_comment": "Dev environment Flink configuration. ...",
  "organization_id":     "<DKP Confluent org UUID>",
  "environment_id":      "<env-XXXXX for this stage>",
  "service_account_id":  "<sa-XXXXX for this stage>",
  "compute_pool": {
    "display_name": "dkp-flink-dev-pool",
    "cloud":        "AWS",
    "region":       "us-east-2",
    "max_cfu":      5
  },
  "statements": {
    "your_statement_key": {
      "name": "your-statement-name",
      "sql":  "INSERT INTO `target.topic` SELECT * FROM `source.topic`",
      "properties": {
        "sql.current-catalog":  "<env-display-name>",
        "sql.current-database": "<kafka-cluster-display-name>"
      },
      "stopped": false
    }
  }
}
```

| Field | Notes |
|---|---|
| `organization_id` | Confluent org UUID. Same value across dev/uat/prd in a single org. |
| `environment_id` | Stage-specific env-XXXXX. |
| `service_account_id` | sa-XXXXX of the SA that owns the Flink statements. |
| `compute_pool.cloud` | AWS / AZURE / GCP. Must match the Kafka cluster's cloud. |
| `compute_pool.region` | Must match the Kafka cluster's region. |
| `compute_pool.max_cfu` | Max CFU autoscale ceiling. Min 5. Typical: dev=5, uat=10, prd=20+. |
| `statements` | Map keyed by your local identifier. Each entry: `name`, `sql`, `properties`, `stopped`. Multiple statements per env supported. |

**SQL gotchas worth knowing up front:**

- **Backtick-quote topic and column names that contain dots, hyphens, or special characters.** Without backticks, Flink parses dots as `catalog.database.table` separators.
- **`INSERT INTO` requires the target topic to exist.** Either pre-create it, or use `CREATE TABLE <target> AS SELECT ...` (CTAS) which creates the topic + schema atomically.
- **Avoid non-deterministic functions** (`NOW()`, `RAND()`, `CURRENT_TIMESTAMP`) — they break restart-safety. Use event-time columns from the source instead.

## Usage

### Recommended path — CI/CD via GitHub Actions

For all environments, especially production:

> **Actions tab → terraform-flink → Run workflow → choose stack and action**

Inputs:

| Input | Options | Default |
|---|---|---|
| `stack` | `dev` / `uat` / `prd` | `dev` |
| `action` | `plan` / `apply` / `destroy` | `plan` |

PR triggers also auto-run plan against `dev` for any change to `terraform/**` or `tools/**`.

For why CI/CD is the recommended path even though local CLI works, see [`docs/ci-cd-vs-local-cli.md`](docs/ci-cd-vs-local-cli.md).

### Local CLI (dev iteration, debugging, break-glass)

```bash
# Install pinned tools
bash tools/install.sh
export PATH="$(pwd)/tools/bin:$PATH"

# Source Azure SP creds + Azure state location + AKV identifiers from .env.azure
# (paste these from the bootstrap script's output; .env files are gitignored)
set -a; source .env.azure; set +a

# Apply both stacks for an env
cd terraform/live/dev
terragrunt run-all init
terragrunt run-all plan
terragrunt run-all apply

# Apply only one stack
cd terraform/live/dev/compute-pool && terragrunt apply
cd terraform/live/dev/statements   && terragrunt apply

# Destroy only statements (keep pool running)
cd terraform/live/dev/statements && terragrunt destroy
```

For more partial-scope patterns, see [`docs/scoped-operations.md`](docs/scoped-operations.md).

## Modules

### `confluent-flink-compute-pool`

Creates a Flink compute pool and looks up the region's Flink REST endpoint.

| Input | Type | Description |
|---|---|---|
| `environment_id` | string | Confluent environment ID (env-XXXXX) |
| `display_name` | string | Pool display name |
| `cloud` | string | AWS / AZURE / GCP |
| `region` | string | Cloud region |
| `max_cfu` | number | Max CFUs (default 5) |

| Output | Description |
|---|---|
| `id` | Compute pool ID (lfcp-XXXXX) |
| `display_name` | Pool display name |
| `resource_name` | Full Confluent resource name |
| `flink_rest_endpoint` | Region-scoped Flink REST endpoint |

### `confluent-flink-statements`

Creates Flink SQL statements via `for_each` over the `statements` map. Each map entry becomes a separate `confluent_flink_statement` resource. Pulls compute_pool_id + flink_rest_endpoint from the compute-pool stack via Terragrunt dependency. Pulls Flink credentials from AKV via the generated `provider.tf`.

| Input | Type | Description |
|---|---|---|
| `environment_id` | string | Confluent environment ID |
| `compute_pool_id` | string | From compute-pool stack output |
| `principal_id` | string | sa-XXXXX (from `flink-config.json`) |
| `flink_rest_endpoint` | string | From compute-pool stack output |
| `statements` | map | Map of statement entries (name, sql, properties, stopped) |

| Output | Description |
|---|---|
| `statement_ids` | Map of local-identifier → Confluent statement ID |
| `statement_names` | Map of local-identifier → Confluent statement display name |

## Service account RBAC

The service account referenced as `service_account_id` in `flink-config.json` needs the following role bindings in Confluent Cloud:

| Role | Resource | Why |
|---|---|---|
| `FlinkAdmin` | Environment | Create / scale / delete the compute pool |
| `FlinkDeveloper` | Environment (or compute pool) | Submit Flink statements |
| `DeveloperRead` | `Topic:*` (or specific source topics) | Read source topic data |
| `DeveloperWrite` | `Topic:*` (or specific sink topics) | Write sink topic data |
| `DeveloperRead` | `Subject:*-value` (Schema Registry) | Resolve source schemas |
| `DeveloperWrite` | `Subject:*-value` (Schema Registry) | Register sink schemas (CTAS) |
| **`DeveloperWrite`** | **`TransactionalId:*`** | **Required for exactly-once writes. Skipping this causes runtime `Transactional Id authorization failed`.** |

For tighter scoping in production, replace wildcards with specific resource patterns. See [`docs/dkp-onboarding.md`](docs/dkp-onboarding.md) Phase 2.3 for the exact CLI commands.

## Lifecycle operations

After initial setup, the GitOps pattern is:

| Operation | How |
|---|---|
| Add a new statement | Edit `flink-config.json` → PR → merge → workflow_dispatch apply |
| Modify a statement's SQL or properties | Same as above (note: SQL changes recreate the resource — fresh checkpoint) |
| Stop a statement (preserve savepoint) | Set `"stopped": true` → PR → apply (in-place update, no destroy) |
| Resume | Set `"stopped": false` → PR → apply (resumes from savepoint) |
| Destroy a single statement | Remove its entry from `statements` map → PR → apply |
| Destroy all statements (keep pool) | `cd terraform/live/<env>/statements && terragrunt destroy` (CLI), or `statements: {}` → apply |
| Tear everything down | workflow_dispatch with `action: destroy` |

## Tooling

Pinned tool versions live in `tools/versions.env`. Both CI and local invocations use the same versions via `tools/install.sh` (idempotent).

```bash
bash tools/install.sh
export PATH="$(pwd)/tools/bin:$PATH"
```

For one-time Azure state setup (storage account, container, AKV, service principal), see `tools/bootstrap-azure-state.sh`. Run once per Azure subscription.

## What's intentionally out of scope of this repo

- **Confluent environment / Kafka cluster provisioning.** This repo manages Flink resources only. The Confluent envs and Kafka clusters they run on are assumed to exist (provisioned separately).
- **Source / target Kafka topic provisioning.** This repo does not create the topics that Flink statements read from or write to. Either pre-create them or use CTAS to let Flink create the target.
- **Schema management for source topics.** Source schemas are read; not modified.
- **Confluent service account creation.** SAs are referenced by ID; provisioning them is out of scope (typically managed via a separate workflow-identity repo or the Confluent UI).
