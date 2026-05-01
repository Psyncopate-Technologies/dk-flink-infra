# `modules/confluent-flink-statements/`

Reusable Terraform module that provisions one or more Confluent Cloud Flink statements via `for_each` over a map. Each map entry becomes a separate `confluent_flink_statement` resource on the same compute pool.

## What it creates

| Resource | Purpose |
|---|---|
| `data.confluent_environment.this` | Looks up the env by ID |
| `data.confluent_organization.this` | Resolves the org context for the principal binding |
| `confluent_flink_statement.statements[<map-key>]` | One per entry in the `statements` map |

## Inputs

| Name | Type | Required | Description |
|---|---|---|---|
| `environment_id` | string | yes | Confluent environment ID (env-XXXXX) |
| `compute_pool_id` | string | yes | Pool ID (lfcp-XXXXX), wired from the compute-pool stack via Terragrunt dependency |
| `principal_id` | string | yes | sa-XXXXX — the service account each statement runs as |
| `flink_rest_endpoint` | string | yes | Region's Flink REST endpoint, also wired from the compute-pool stack |
| `statements` | map(object) | yes | Map of statements to deploy — see schema below |

### `statements` map schema

```hcl
map(object({
  name       = string
  sql        = string
  properties = optional(map(string), {})
  stopped    = optional(bool, false)
}))
```

| Key | Description |
|---|---|
| `name` | Display name shown in Confluent UI. Must be unique within the env. Kebab-case suggested. |
| `sql` | Flink SQL — typically `INSERT INTO ... SELECT ...` or `CREATE TABLE ... AS SELECT ...` |
| `properties` | Optional. Common: `sql.current-catalog` (env display name), `sql.current-database` (cluster display name) |
| `stopped` | Optional. `false` (default) = run; `true` = stop. Flipping false→true triggers an in-place stop with savepoint preserved |

## Outputs

| Name | Description |
|---|---|
| `statement_ids` | Map of local-identifier → Confluent statement ID |
| `statement_names` | Map of local-identifier → Confluent statement display name |

## How it's invoked

This module is consumed by each environment's `statements/terragrunt.hcl`, e.g.:

```hcl
# terraform/live/dev/statements/terragrunt.hcl
dependency "compute_pool" {
  config_path = "../compute-pool"
  mock_outputs = {
    id                  = "lfcp-mock00000"
    flink_rest_endpoint = "https://flink.mock.confluent.cloud"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "destroy"]
}

terraform {
  source = "../../../modules/confluent-flink-statements"
}

inputs = {
  environment_id      = local.config.environment_id
  principal_id        = local.config.service_account_id
  compute_pool_id     = dependency.compute_pool.outputs.id
  flink_rest_endpoint = dependency.compute_pool.outputs.flink_rest_endpoint
  statements          = local.config.statements
}
```

## Provider authentication for Flink

Each `confluent_flink_statement` resource needs Flink-scoped credentials (separate from the cloud-scoped API key). These come from the **provider config in the generated `provider.tf`** (which `root.hcl` builds), pulling them from AKV. The resource also has an inline `credentials { key, secret }` block that references those AKV-sourced values directly.

The user-controlled inputs to this module do **not** include API keys — credentials are infrastructure-level, not configuration-level.

## Dependencies

- The compute-pool stack must already be applied (or mocked for plan-time) — its outputs supply `compute_pool_id` and `flink_rest_endpoint`.
- The `confluent` and `azurerm` Terraform providers must be available (declared in `versions.tf`).
- The service account `principal_id` must have these roles in Confluent (see top-level `README.md` § Service account RBAC):
  - `FlinkDeveloper` on the compute pool
  - `DeveloperRead/Write` on relevant topics + Schema Registry subjects
  - `DeveloperWrite` on `TransactionalId:*` (for exactly-once writes)

## Lifecycle behaviors

| Change in `statements` map | Terraform action |
|---|---|
| Add a new entry | Create a new statement |
| Remove an entry | Destroy that statement |
| Change `stopped` value | In-place update (savepoint preserved on stop, resumed from savepoint on resume) |
| Change `sql` or `properties` | **Destroy + recreate** (statement-id changes, fresh checkpoint) |

For partial-scope ops (destroy only some statements, stop one specific one), see [`../../../docs/scoped-operations.md`](../../../docs/scoped-operations.md).
