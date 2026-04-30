# -----------------------------------------------------------------------------
# Flink SQL Statements
# -----------------------------------------------------------------------------
# Creates Flink SQL statements in the specified compute pool.
# Statements can be used to define streaming transformations, aggregations,
# and data pipelines using Flink SQL.
# -----------------------------------------------------------------------------

data "confluent_environment" "this" {
  id = var.environment_id
}

data "confluent_organization" "this" {}

resource "confluent_flink_statement" "statements" {
  for_each = var.statements

  organization {
    id = data.confluent_organization.this.id
  }

  environment {
    id = data.confluent_environment.this.id
  }

  compute_pool {
    id = var.compute_pool_id
  }

  principal {
    id = var.principal_id
  }

  rest_endpoint = var.flink_rest_endpoint

  # Flink credentials are read from AKV via the data sources declared in
  # root.hcl's generated provider.tf (same init dir, accessible by name).
  # Resource-level credentials are needed because the Confluent provider's
  # flink_* attributes are all-or-nothing — we'd have to also set
  # rest_endpoint / compute_pool_id / environment_id at the provider level,
  # which can't work since those are per-stack.
  credentials {
    key    = data.azurerm_key_vault_secret.confluent_flink_key.value
    secret = data.azurerm_key_vault_secret.confluent_flink_secret.value
  }

  statement  = each.value.sql
  properties = each.value.properties
  stopped    = each.value.stopped

  # Flink statements can take time to provision
  timeouts {
    create = "10m"
  }
}
