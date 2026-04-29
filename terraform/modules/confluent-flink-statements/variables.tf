variable "environment_id" {
  description = "Confluent Cloud environment ID (env-*)."
  type        = string
}

variable "compute_pool_id" {
  description = "Flink compute pool ID (lfcp-*)."
  type        = string
}

variable "principal_id" {
  description = "Service account ID (sa-*) that will own and run the Flink statements."
  type        = string
}

variable "flink_rest_endpoint" {
  description = "Flink REST endpoint for the compute pool's region."
  type        = string
}

variable "flink_api_key" {
  description = "Flink-scoped API key (different from the cloud API key)."
  type        = string
  sensitive   = true
}

variable "flink_api_secret" {
  description = "Flink-scoped API secret (different from the cloud API secret)."
  type        = string
  sensitive   = true
}

variable "statements" {
  description = <<EOT
Map of Flink SQL statements to create.

Each statement:
  name       - Display name for the statement.
  sql        - The Flink SQL statement to execute.
  properties - Optional map of statement properties (e.g., sql.current-catalog, sql.current-database).
  stopped    - Optional boolean to create the statement in stopped state (default: false).
EOT
  type = map(object({
    name       = string
    sql        = string
    properties = optional(map(string), {})
    stopped    = optional(bool, false)
  }))
  default = {}
}
