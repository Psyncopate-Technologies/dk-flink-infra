# `modules/confluent-flink-compute-pool/`

Reusable Terraform module that provisions a single Confluent Cloud Flink compute pool and exposes the region's Flink REST endpoint as an output.

## What it creates

| Resource | Purpose |
|---|---|
| `data.confluent_environment.this` | Looks up the env by ID (validates env exists) |
| `data.confluent_flink_region.this` | Looks up the Flink region (returns the region's REST endpoint) |
| `confluent_flink_compute_pool.this` | The compute pool resource |

## Inputs

| Name | Type | Required | Description |
|---|---|---|---|
| `environment_id` | string | yes | Confluent environment ID (env-XXXXX) |
| `display_name` | string | yes | Human-readable pool name |
| `cloud` | string | yes | `AWS` / `AZURE` / `GCP`. Must match the Kafka cluster's cloud |
| `region` | string | yes | Cloud region. Must match the Kafka cluster's region |
| `max_cfu` | number | no (default 5) | Maximum CFUs the pool autoscales to. Min 5 |

## Outputs

| Name | Description |
|---|---|
| `id` | Compute pool ID (lfcp-XXXXX). Consumed by the statements stack via Terragrunt dependency |
| `display_name` | Echoed back from input |
| `resource_name` | Full Confluent CRN of the pool |
| `flink_rest_endpoint` | Region-scoped Flink REST endpoint (used by `confluent_flink_statement.rest_endpoint`) |

## How it's invoked

This module is consumed by each environment's `compute-pool/terragrunt.hcl`, e.g.:

```hcl
# terraform/live/dev/compute-pool/terragrunt.hcl
terraform {
  source = "../../../modules/confluent-flink-compute-pool"
}

inputs = {
  environment_id = local.config.environment_id
  display_name   = local.config.compute_pool.display_name
  cloud          = local.config.compute_pool.cloud
  region         = local.config.compute_pool.region
  max_cfu        = local.config.compute_pool.max_cfu
}
```

The `confluent` provider that this module uses is configured in the **generated `provider.tf`** that `terraform/live/root.hcl` produces — pulling cloud_api_key/secret from AKV at plan/apply time. This module itself contains no provider configuration.

## Dependencies

- The `confluent` Terraform provider must be available (declared in `versions.tf`).
- Cloud-scoped Confluent API credentials with `FlinkAdmin` on the target environment.

## Notes

- The `data.confluent_flink_region` lookup is what resolves `flink_rest_endpoint`. That endpoint is region-deterministic and not user-configurable; you don't override it in the inputs.
- The `display_name` is unique within the environment. Apply will fail if a pool with the same display name already exists in that env.
