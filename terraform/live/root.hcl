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
# -----------------------------------------------------------------------------
# Generated provider config (overwritten by terragrunt on every run).
#
# Pulls Confluent Cloud admin + Flink API credentials from Azure Key Vault
# at plan/apply time — secrets never enter Terraform state or CI env vars.
# Auth to Azure comes from ARM_* env vars set by the workflow (CI) or from
# \`az login\` (local).
# -----------------------------------------------------------------------------

provider "azurerm" {
  features {}
}

data "azurerm_key_vault" "this" {
  name                = var.azure_key_vault_name
  resource_group_name = var.azure_key_vault_resource_group_name
}

# Cloud-scoped admin key — manages compute pools, environments, etc.
data "azurerm_key_vault_secret" "confluent_admin_key" {
  name         = "confluent-admin-key"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "confluent_admin_secret" {
  name         = "confluent-admin-secret"
  key_vault_id = data.azurerm_key_vault.this.id
}

# Flink-region-scoped key — submits statements. Owned by the service account
# referenced as service_account_id in flink-config.json.
data "azurerm_key_vault_secret" "confluent_flink_key" {
  name         = "confluent-flink-key"
  key_vault_id = data.azurerm_key_vault.this.id
}

data "azurerm_key_vault_secret" "confluent_flink_secret" {
  name         = "confluent-flink-secret"
  key_vault_id = data.azurerm_key_vault.this.id
}

# Provider configured with both cloud and Flink credentials. Resources inherit
# automatically — confluent_flink_statement no longer needs its own
# \`credentials\` block.
provider "confluent" {
  cloud_api_key    = data.azurerm_key_vault_secret.confluent_admin_key.value
  cloud_api_secret = data.azurerm_key_vault_secret.confluent_admin_secret.value
  flink_api_key    = data.azurerm_key_vault_secret.confluent_flink_key.value
  flink_api_secret = data.azurerm_key_vault_secret.confluent_flink_secret.value
}

variable "azure_key_vault_name" {
  description = "Name of the AKV holding Confluent secrets. Supply via TF_VAR_azure_key_vault_name."
  type        = string
}

variable "azure_key_vault_resource_group_name" {
  description = "Resource group of the AKV above. Supply via TF_VAR_azure_key_vault_resource_group_name."
  type        = string
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

    # Use the AAD identity (ARM_CLIENT_ID/SECRET) directly for blob ops.
    # Without this, the backend tries Microsoft.Storage/storageAccounts/listKeys,
    # which our SP doesn't have (data-plane RBAC only). With this, the SP's
    # `Storage Blob Data Contributor` role on the SA is exactly enough.
    use_azuread_auth = true
  }
}
