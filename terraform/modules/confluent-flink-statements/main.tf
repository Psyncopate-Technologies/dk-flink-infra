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

data "confluent_flink_compute_pool" "this" {
  id = var.compute_pool_id

  environment {
    id = data.confluent_environment.this.id
  }
}

data "confluent_organization" "this" {
  id = var.organization_id
}

resource "confluent_flink_statement" "statements" {
  for_each = var.statements

  organization {
    id = data.confluent_organization.this.id
  }

  environment {
    id = data.confluent_environment.this.id
  }

  compute_pool {
    id = data.confluent_flink_compute_pool.this.id
  }

  principal {
    id = var.principal_id
  }

  statement  = each.value.sql
  properties = each.value.properties
  stopped    = each.value.stopped

  # Flink statements can take time to provision
  timeouts {
    create = "10m"
  }
}
