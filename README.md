# DKP Flink Terraform

Terraform/Terragrunt infrastructure for managing Confluent Cloud Flink resources.

## Overview

This repository provisions:
- **Flink Compute Pools** — Compute resources for running Flink SQL
- **Flink Statements** — SQL statements for streaming transformations

## Project Structure

```
dkp-flink-terraform/
├── README.md
├── .gitignore
└── terraform/
    ├── live/
    │   ├── root.hcl                                   # Common Terragrunt config
    │   ├── dev/
    │   │   ├── flink-config.json                      # Shared dev config (compute pool + statements)
    │   │   ├── compute-pool/
    │   │   │   └── terragrunt.hcl                     # Provisions the Flink compute pool
    │   │   └── statements/
    │   │       └── terragrunt.hcl                     # Provisions Flink SQL statements (depends on compute-pool)
    │   ├── uat/
    │   │   ├── flink-config.json
    │   │   ├── compute-pool/terragrunt.hcl
    │   │   └── statements/terragrunt.hcl
    │   └── prd/
    │       ├── flink-config.json
    │       ├── compute-pool/terragrunt.hcl
    │       └── statements/terragrunt.hcl
    └── modules/
        ├── confluent-flink-compute-pool/      # Compute pool module
        │   ├── main.tf
        │   ├── variables.tf
        │   ├── outputs.tf
        │   └── versions.tf
        └── confluent-flink-statements/        # Flink statements module
            ├── main.tf
            ├── variables.tf
            ├── outputs.tf
            └── versions.tf
```

Each environment is split into two Terragrunt stacks: `compute-pool/` and `statements/`. The statements stack declares a `dependency` on the compute-pool stack and pulls the pool's `id` output as `compute_pool_id`, so `terragrunt run-all apply` applies them in the correct order.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.9
- [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) >= 0.50
- Confluent Cloud account with Flink enabled
- Service account with `FlinkAdmin` role

## Configuration

### Environment Variables

Two API keys are required. The cloud-scoped key manages the compute pool; a separate Flink-scoped key (pre-created in Confluent Cloud and stored in AKV / your secret store) authorizes statement submission.

```bash
# Cloud-scoped (manages compute pools, environments, etc.)
export TF_VAR_confluent_cloud_api_key="<cloud-api-key>"
export TF_VAR_confluent_cloud_api_secret="<cloud-api-secret>"

# Flink-scoped (submits statements to the compute pool)
# Required only by the statements stack. Owned by the service account
# referenced as service_account_id in flink-config.json.
export TF_VAR_confluent_flink_api_key="<flink-api-key>"
export TF_VAR_confluent_flink_api_secret="<flink-api-secret>"
```

The Flink API key is intentionally **not** managed by Terraform: it's expected to live in AKV and be injected via env vars by the deployment pipeline, so the secret never lands in Terraform state.

### Flink Configuration

Each environment has a single `flink-config.json` shared between the `compute-pool` and `statements` stacks:

| Field | Description |
|-------|-------------|
| `organization_id` | Confluent Cloud organization ID |
| `environment_id` | Environment ID (env-*) |
| `service_account_id` | Service account for Flink (sa-*) |
| `compute_pool.display_name` | Name for the compute pool |
| `compute_pool.cloud` | Cloud provider (AWS, AZURE, GCP) |
| `compute_pool.region` | Cloud region |
| `compute_pool.max_cfu` | Maximum CFUs (5-150) |
| `statements` | Map of Flink SQL statements (see below) |

#### Statements

`statements` is a map keyed by statement identifier. Keys prefixed with `_` (e.g. `_comment`, `_example`) are filtered out by the statements stack so the file can carry inline documentation. An entry looks like:

```json
"statements": {
  "my_first_statement": {
    "name": "my_first_statement",
    "sql": "SELECT * FROM my_table;",
    "properties": {
      "sql.current-catalog": "my-catalog",
      "sql.current-database": "my-database"
    },
    "stopped": false
  }
}
```

## Usage

### Apply both stacks (recommended)

From the environment root, `run-all` walks both stacks and respects the dependency:

```bash
cd terraform/live/dev
terragrunt run-all init
terragrunt run-all plan
terragrunt run-all apply
```

### Apply a single stack

```bash
# Compute pool only
cd terraform/live/dev/compute-pool
terragrunt apply

# Statements only (compute pool must already exist)
cd terraform/live/dev/statements
terragrunt apply
```

### Destroy

`run-all destroy` tears down statements first, then the compute pool:

```bash
cd terraform/live/dev
terragrunt run-all destroy
```

## CI/CD

A plan-only GitHub Actions workflow lives at `.github/workflows/terraform-flink.yml`. It runs `terragrunt plan --all` against the chosen environment on every PR touching `terraform/**` or `tools/**`, and on manual `workflow_dispatch`. Apply/destroy are intentionally not exposed yet because the local backend can't persist state across runners — once a remote backend is added, an apply job will follow.

See `.github/README.md` for the four required GitHub secrets (`CONFLUENT_CLOUD_API_KEY`, `CONFLUENT_CLOUD_API_SECRET`, `CONFLUENT_FLINK_API_KEY`, `CONFLUENT_FLINK_API_SECRET`) and the local CLI equivalent.

Pinned tool versions live in `tools/versions.env`; `tools/install.sh` downloads them into `tools/bin/` (idempotent, used identically by CI and local).

## Modules

### confluent-flink-compute-pool

Creates a Flink compute pool and looks up the region's Flink REST endpoint for downstream consumers.

| Input | Type | Description |
|-------|------|-------------|
| `environment_id` | string | Environment ID (env-*) |
| `display_name` | string | Pool display name |
| `cloud` | string | Cloud provider |
| `region` | string | Cloud region |
| `max_cfu` | number | Max CFUs (default: 5) |

| Output | Description |
|--------|-------------|
| `id` | Compute pool ID (lfcp-*) |
| `display_name` | Pool display name |
| `resource_name` | Full resource name |
| `flink_rest_endpoint` | Region-scoped Flink REST endpoint |

### confluent-flink-statements

Creates Flink SQL statements. The `flink_rest_endpoint` is pulled from the compute-pool dependency; `flink_api_key` and `flink_api_secret` come from env vars (`TF_VAR_confluent_flink_api_key` / `TF_VAR_confluent_flink_api_secret`) so the Flink API key — owned by a pre-existing service account and stored in AKV — never lands in Terraform state.

| Input | Type | Description |
|-------|------|-------------|
| `environment_id` | string | Environment ID |
| `compute_pool_id` | string | Compute pool ID (from compute-pool output) |
| `principal_id` | string | Service account ID |
| `flink_rest_endpoint` | string | Flink REST endpoint (from compute-pool output) |
| `flink_api_key` | string | Flink API key (sensitive, from env var) |
| `flink_api_secret` | string | Flink API secret (sensitive, from env var) |
| `statements` | map | Map of SQL statements |

| Output | Description |
|--------|-------------|
| `statement_ids` | Map of statement IDs |
| `statement_names` | Map of statement names |

## Service Account RBAC

The service account needs the following roles:

| Role | Scope | Purpose |
|------|-------|---------|
| `FlinkAdmin` | Environment | Create/manage compute pools |
| `FlinkDeveloper` | Compute Pool | Run Flink statements |
| `DeveloperRead` | Kafka Topics | Read source topics |
| `DeveloperWrite` | Kafka Topics | Write sink topics |

## Current Configuration

| Parameter | Value |
|-----------|-------|
| Organization ID | `0369af3f-d68c-44de-97cb-52a50017dc59` |
| Environment ID | `env-1y1176` |
| Service Account | `sa-nv299xk` |
| Cloud | AWS |
| Region | us-east-2 |
