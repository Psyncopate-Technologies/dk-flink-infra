# -----------------------------------------------------------------------------
# Dev Environment — Flink Compute Pool + Statements
# -----------------------------------------------------------------------------
# Creates a Flink compute pool and optional SQL statements for the dev
# environment. Configuration values are loaded from flink-config.json.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  config = jsondecode(file("${get_terragrunt_dir()}/flink-config.json"))
}

terraform {
  source = "../../modules/confluent-flink-compute-pool"
}

inputs = {
  environment_id = local.config.environment_id
  display_name   = local.config.compute_pool.display_name
  cloud          = local.config.compute_pool.cloud
  region         = local.config.compute_pool.region
  max_cfu        = local.config.compute_pool.max_cfu
}
