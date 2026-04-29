variable "environment_id" {
  description = "Confluent Cloud environment ID (env-*)."
  type        = string
}

variable "display_name" {
  description = "Display name for the Flink compute pool."
  type        = string
}

variable "cloud" {
  description = "Cloud provider for the compute pool (AWS, AZURE, GCP)."
  type        = string
  default     = "AWS"

  validation {
    condition     = contains(["AWS", "AZURE", "GCP"], var.cloud)
    error_message = "cloud must be one of: AWS, AZURE, GCP."
  }
}

variable "region" {
  description = "Cloud region for the compute pool (e.g., us-east-2, eastus)."
  type        = string
}

variable "max_cfu" {
  description = "Maximum Confluent Flink Units (CFUs) for the compute pool. Min: 5, Max: 150."
  type        = number
  default     = 5

  validation {
    condition     = var.max_cfu >= 5 && var.max_cfu <= 150
    error_message = "max_cfu must be between 5 and 150."
  }
}
