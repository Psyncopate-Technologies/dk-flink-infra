# -----------------------------------------------------------------------------
# Flink Compute Pool
# -----------------------------------------------------------------------------
# Creates a Flink compute pool in the specified Confluent Cloud environment.
# The compute pool provides the compute resources for running Flink SQL statements.
# -----------------------------------------------------------------------------

data "confluent_environment" "this" {
  id = var.environment_id
}

resource "confluent_flink_compute_pool" "this" {
  display_name = var.display_name
  cloud        = var.cloud
  region       = var.region
  max_cfu      = var.max_cfu

  environment {
    id = data.confluent_environment.this.id
  }
}
