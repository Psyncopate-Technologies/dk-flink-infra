output "statement_ids" {
  description = "Map of statement names to their IDs."
  value = {
    for k, v in confluent_flink_statement.statements : k => v.id
  }
}

output "statement_names" {
  description = "Map of statement keys to their display names."
  value = {
    for k, v in confluent_flink_statement.statements : k => v.statement_name
  }
}
