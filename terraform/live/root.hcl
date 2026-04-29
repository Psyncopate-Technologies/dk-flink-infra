# -----------------------------------------------------------------------------
# Root Terragrunt Configuration — Flink Infrastructure
# -----------------------------------------------------------------------------
# Common configuration for all Flink stacks. Generates provider.tf with
# Confluent Cloud authentication using API key + secret from environment
# variables.
# -----------------------------------------------------------------------------

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "~> 2.10"
    }
  }
}

# Confluent Cloud provider — credentials from environment variables.
# Set TF_VAR_confluent_cloud_api_key and TF_VAR_confluent_cloud_api_secret
# before running terragrunt.
provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret
}

variable "confluent_cloud_api_key" {
  description = "Confluent Cloud API key. Supply via TF_VAR_confluent_cloud_api_key."
  type        = string
  sensitive   = true
}

variable "confluent_cloud_api_secret" {
  description = "Confluent Cloud API secret. Supply via TF_VAR_confluent_cloud_api_secret."
  type        = string
  sensitive   = true
}
EOF
}

# -----------------------------------------------------------------------------
# Remote State — Local backend for PoC
# -----------------------------------------------------------------------------
# For production, switch to azurerm backend similar to the workload-identity
# repo. Local state is sufficient for initial testing.
# -----------------------------------------------------------------------------

remote_state {
  backend = "local"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    path = "${path_relative_to_include()}/terraform.tfstate"
  }
}
