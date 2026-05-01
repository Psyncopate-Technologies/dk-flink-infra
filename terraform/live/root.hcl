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

data "azurerm_key_vault" "corp_it" {
  name                = var.azure_key_vault_name
  resource_group_name = var.azure_key_vault_resource_group_name
}

# Cloud-scoped admin key — manages compute pools, environments, etc.
data "azurerm_key_vault_secret" "confluent_admin_key" {
  name         = "confluent-admin-key"
  key_vault_id = data.azurerm_key_vault.corp_it.id
}

data "azurerm_key_vault_secret" "confluent_admin_secret" {
  name         = "confluent-admin-secret"
  key_vault_id = data.azurerm_key_vault.corp_it.id
}

# Flink-region-scoped key — submits statements. Owned by the service account
# referenced as service_account_id in flink-config.json.
data "azurerm_key_vault_secret" "confluent_flink_key" {
  name         = "confluent-flink-key"
  key_vault_id = data.azurerm_key_vault.corp_it.id
}

data "azurerm_key_vault_secret" "confluent_flink_secret" {
  name         = "confluent-flink-secret"
  key_vault_id = data.azurerm_key_vault.corp_it.id
}

# Cloud-level credentials only — Flink credentials go on the
# confluent_flink_statement resource directly (the provider's flink_* fields
# must be all-or-nothing across 7 attributes, several of which are per-stack
# and only known after the compute-pool dependency resolves).
provider "confluent" {
  cloud_api_key    = data.azurerm_key_vault_secret.confluent_admin_key.value
  cloud_api_secret = data.azurerm_key_vault_secret.confluent_admin_secret.value
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
# Auth: OIDC / Workload Identity Federation in CI. The workflow sets
# ARM_USE_OIDC=true and provides ARM_TENANT_ID / ARM_SUBSCRIPTION_ID /
# ARM_CLIENT_ID; the azurerm SDK exchanges the GitHub OIDC token for an
# Azure access token. No client secret is stored. Locally, ARM_USE_OIDC is
# unset and the SDK falls through to `az login` (Azure CLI) auth.
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

    # Use the AAD identity directly for blob ops (data-plane RBAC).
    # Without this, the backend tries Microsoft.Storage/storageAccounts/listKeys
    # which the SP doesn't have (only `Storage Blob Data Contributor`).
    use_azuread_auth = true

    # OIDC path — turned on by the workflow via ARM_USE_OIDC=true. When unset
    # (local CLI), the backend falls through to `az login` auth.
    use_oidc = get_env("ARM_USE_OIDC", "false") == "true"

    # Pass identifiers explicitly so the auth chain short-circuits and never
    # tries MSI / IMDS fallbacks. On GitHub-hosted runners (not on Azure VMs)
    # the IMDS endpoint at 169.254.169.254 doesn't answer, and the Azure SDK
    # waits ~3 minutes before giving up — the symptom we hit when
    # `Initializing the backend...` hung forever in the SP+secret era.
    # Empty defaults are fine locally: the backend ignores empty strings and
    # falls through to Azure CLI auth.
    tenant_id       = get_env("ARM_TENANT_ID", "")
    subscription_id = get_env("ARM_SUBSCRIPTION_ID", "")
    client_id       = get_env("ARM_CLIENT_ID", "")
  }
}
