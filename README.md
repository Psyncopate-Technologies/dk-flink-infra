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
    │   ├── root.hcl                           # Common Terragrunt config
    │   ├── dev/
    │   │   ├── terragrunt.hcl                 # Dev environment config
    │   │   └── flink-config.json              # Dev Flink configuration
    │   ├── uat/
    │   │   ├── terragrunt.hcl
    │   │   └── flink-config.json
    │   └── prd/
    │       ├── terragrunt.hcl
    │       └── flink-config.json
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

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.9
- [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) >= 0.50
- Confluent Cloud account with Flink enabled
- Service account with `FlinkAdmin` role

## Configuration

### Environment Variables

Set the following before running Terragrunt:

```bash
export TF_VAR_confluent_cloud_api_key="<your-api-key>"
export TF_VAR_confluent_cloud_api_secret="<your-api-secret>"
```

### Flink Configuration

Each environment has a `flink-config.json` file:

| Field | Description |
|-------|-------------|
| `organization_id` | Confluent Cloud organization ID |
| `environment_id` | Environment ID (env-*) |
| `service_account_id` | Service account for Flink (sa-*) |
| `compute_pool.display_name` | Name for the compute pool |
| `compute_pool.cloud` | Cloud provider (AWS, AZURE, GCP) |
| `compute_pool.region` | Cloud region |
| `compute_pool.max_cfu` | Maximum CFUs (5-150) |

## Usage

### Initialize and Plan

```bash
cd terraform/live/dev
terragrunt init
terragrunt plan
```

### Apply

```bash
terragrunt apply
```

### Destroy

```bash
terragrunt destroy
```

## Modules

### confluent-flink-compute-pool

Creates a Flink compute pool.

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

### confluent-flink-statements

Creates Flink SQL statements.

| Input | Type | Description |
|-------|------|-------------|
| `environment_id` | string | Environment ID |
| `compute_pool_id` | string | Compute pool ID |
| `principal_id` | string | Service account ID |
| `organization_id` | string | Organization ID |
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
