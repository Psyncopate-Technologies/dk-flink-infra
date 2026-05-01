# -----------------------------------------------------------------------------
# Dev — Flink SQL Statements
# -----------------------------------------------------------------------------
# Creates Flink SQL statements on the compute pool provisioned by the
# sibling compute-pool stack. The dependency block pulls the pool ID from
# that stack's outputs, so `terragrunt run-all apply` applies them in order.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  config = jsondecode(file("${get_terragrunt_dir()}/../flink-config.json"))
}

dependency "compute_pool" {
  config_path = "../compute-pool"

  # Allow plan/validate before the compute pool exists.
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

  # Flink credentials are configured at the provider level (root.hcl pulls
  # them from AKV) — no per-resource credentials block needed.
}
