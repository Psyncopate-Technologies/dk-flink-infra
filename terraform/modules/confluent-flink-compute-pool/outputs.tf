output "id" {
  description = "The ID of the Flink compute pool (lfcp-*)."
  value       = confluent_flink_compute_pool.this.id
}

output "display_name" {
  description = "The display name of the Flink compute pool."
  value       = confluent_flink_compute_pool.this.display_name
}

output "api_version" {
  description = "The API version of the Flink compute pool."
  value       = confluent_flink_compute_pool.this.api_version
}

output "kind" {
  description = "The kind of the Flink compute pool."
  value       = confluent_flink_compute_pool.this.kind
}

output "resource_name" {
  description = "The resource name of the Flink compute pool."
  value       = confluent_flink_compute_pool.this.resource_name
}
