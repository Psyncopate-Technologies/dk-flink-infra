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
# Remote State — Azure Storage (azurerm) backend
# -----------------------------------------------------------------------------
# State location is supplied via env vars so the same root.hcl works locally
# and in CI without code changes:
#
#   TG_STATE_RESOURCE_GROUP   — RG that contains the storage account
#   TG_STATE_STORAGE_ACCOUNT  — globally-unique SA name
#   TG_STATE_CONTAINER        — blob container (defaults to "tfstate")
#
# Auth: ARM_TENANT_ID / ARM_SUBSCRIPTION_ID / ARM_CLIENT_ID /
# ARM_CLIENT_SECRET picked up by the azurerm SDK directly. No OIDC.
# (Locally, `az login` + your user creds also work as a fallback.)
#
# State key is derived from the stack's path, so each stack has its own blob:
#   dev/compute-pool/terraform.tfstate
#   dev/statements/terraform.tfstate
#   uat/compute-pool/terraform.tfstate
#   ...
# -----------------------------------------------------------------------------

remote_state {
  backend = "azurerm"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    resource_group_name  = get_env("TG_STATE_RESOURCE_GROUP")
    storage_account_name = get_env("TG_STATE_STORAGE_ACCOUNT")
    container_name       = get_env("TG_STATE_CONTAINER", "tfstate")
    key                  = "${path_relative_to_include()}/terraform.tfstate"
  }
}
