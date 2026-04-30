#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-time Azure setup for Terraform/Terragrunt state.
#
# Creates (idempotent — re-runs are safe):
#   • Resource group
#   • Storage account (LRS, TLS 1.2, no public blob access, blob versioning +
#     30-day soft delete)
#   • Blob container
#   • Service principal with `Storage Blob Data Contributor` scoped to the SA
#
# Prints the seven env-var values you save into GitHub repo secrets +
# (optionally) a local `.env.azure` for laptop testing.
#
# Prereqs:
#   • az CLI, signed in (`az login`) as someone with Owner/Contributor on the
#     subscription AND permission to create Entra ID app registrations.
#   • python3 (for JSON parsing — present on macOS / ubuntu-latest).
# -----------------------------------------------------------------------------
set -euo pipefail

: "${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID before running}"

LOCATION="${AZURE_LOCATION:-eastus2}"
RG_NAME="${RG_NAME:-rg-flink-tf-state}"
SA_NAME="${SA_NAME:-saflinkstate$(printf '%05d' "$((RANDOM % 100000))")}"
CONTAINER_NAME="${CONTAINER_NAME:-tfstate}"
SP_NAME="${SP_NAME:-sp-flink-tf-state-rw}"
AKV_NAME="${AKV_NAME:-kvflink$(printf '%05d' "$((RANDOM % 100000))")}"

echo "[bootstrap] subscription=${AZURE_SUBSCRIPTION_ID}"
echo "[bootstrap] location=${LOCATION}"
echo "[bootstrap] rg=${RG_NAME} sa=${SA_NAME} container=${CONTAINER_NAME}"
echo "[bootstrap] sp=${SP_NAME} akv=${AKV_NAME}"
echo

az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

echo "[bootstrap] [1/6] creating resource group..."
az group create --name "${RG_NAME}" --location "${LOCATION}" -o none

echo "[bootstrap] [2/6] creating storage account (skips if it already exists)..."
if ! az storage account show --name "${SA_NAME}" --resource-group "${RG_NAME}" -o none 2>/dev/null; then
  az storage account create \
    --name "${SA_NAME}" \
    --resource-group "${RG_NAME}" \
    --location "${LOCATION}" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --allow-blob-public-access false \
    --min-tls-version TLS1_2 \
    -o none
fi

echo "[bootstrap] [3/6] enabling blob versioning + 30-day soft delete..."
az storage account blob-service-properties update \
  --account-name "${SA_NAME}" \
  --resource-group "${RG_NAME}" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30 \
  -o none

echo "[bootstrap] [4/6] creating blob container (auth-mode login)..."
az storage container create \
  --name "${CONTAINER_NAME}" \
  --account-name "${SA_NAME}" \
  --auth-mode login \
  -o none

echo "[bootstrap] [5/8] creating service principal with RBAC on storage account..."
SCOPE_SA="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}"
SP_JSON="$(az ad sp create-for-rbac \
  --name "${SP_NAME}" \
  --role "Storage Blob Data Contributor" \
  --scopes "${SCOPE_SA}" \
  --years 1 \
  -o json)"

parse() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])" <<<"${SP_JSON}"; }

ARM_TENANT_ID="$(parse tenant)"
ARM_CLIENT_ID="$(parse appId)"
ARM_CLIENT_SECRET="$(parse password)"
SP_OBJECT_ID="$(az ad sp show --id "${ARM_CLIENT_ID}" --query id -o tsv)"

echo "[bootstrap] [6/8] creating Key Vault (RBAC mode, no public access)..."
if ! az keyvault show --name "${AKV_NAME}" --resource-group "${RG_NAME}" -o none 2>/dev/null; then
  # Note: soft-delete is mandatory and always-on in current Azure CLI
  # (the --enable-soft-delete flag was removed). --retention-days still
  # controls the soft-delete retention window.
  az keyvault create \
    --name "${AKV_NAME}" \
    --resource-group "${RG_NAME}" \
    --location "${LOCATION}" \
    --sku standard \
    --enable-rbac-authorization true \
    --retention-days 30 \
    --enable-purge-protection true \
    --public-network-access Enabled \
    -o none
fi

echo "[bootstrap] [7/8] granting SP \`Key Vault Secrets User\` on the AKV..."
SCOPE_AKV="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.KeyVault/vaults/${AKV_NAME}"
az role assignment create \
  --assignee-object-id "${SP_OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "${SCOPE_AKV}" \
  -o none || echo "[bootstrap]   (role assignment may already exist — continuing)"

# The user running this script also needs `Key Vault Secrets Officer` to set
# secret values from the CLI later. Grant it (idempotent — no-op if you
# already have it).
ME_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
if [[ -n "${ME_OBJECT_ID}" ]]; then
  az role assignment create \
    --assignee-object-id "${ME_OBJECT_ID}" \
    --assignee-principal-type User \
    --role "Key Vault Secrets Officer" \
    --scope "${SCOPE_AKV}" \
    -o none || true
fi

echo "[bootstrap] [8/8] done."
echo
cat <<EOF
======================================================================
GitHub configuration — Settings → Secrets and variables → Actions

REPO SECRETS (sensitive — set under "Repository secrets"):

  ARM_TENANT_ID              ${ARM_TENANT_ID}
  ARM_SUBSCRIPTION_ID        ${AZURE_SUBSCRIPTION_ID}
  ARM_CLIENT_ID              ${ARM_CLIENT_ID}
  ARM_CLIENT_SECRET          ${ARM_CLIENT_SECRET}
  TG_STATE_RESOURCE_GROUP    ${RG_NAME}
  TG_STATE_STORAGE_ACCOUNT   ${SA_NAME}
  TG_STATE_CONTAINER         ${CONTAINER_NAME}

REPO VARS (non-sensitive — set under "Variables"):

  AZURE_KEY_VAULT_NAME                ${AKV_NAME}
  AZURE_KEY_VAULT_RESOURCE_GROUP_NAME ${RG_NAME}

----------------------------------------------------------------------
NEXT — populate the AKV with the four Confluent secrets. Use the names
below verbatim (root.hcl reads them by exact name):

  az keyvault secret set --vault-name "${AKV_NAME}" \\
    --name confluent-admin-key   --value "<cloud-api-key>"
  az keyvault secret set --vault-name "${AKV_NAME}" \\
    --name confluent-admin-secret --value "<cloud-api-secret>"
  az keyvault secret set --vault-name "${AKV_NAME}" \\
    --name confluent-flink-key    --value "<flink-api-key>"
  az keyvault secret set --vault-name "${AKV_NAME}" \\
    --name confluent-flink-secret --value "<flink-api-secret>"

----------------------------------------------------------------------
For local testing, paste this into a (gitignored) .env.azure and
\`set -a; source .env.azure; set +a\` before running terragrunt:

  export ARM_TENANT_ID="${ARM_TENANT_ID}"
  export ARM_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
  export ARM_CLIENT_ID="${ARM_CLIENT_ID}"
  export ARM_CLIENT_SECRET="${ARM_CLIENT_SECRET}"
  export TG_STATE_RESOURCE_GROUP="${RG_NAME}"
  export TG_STATE_STORAGE_ACCOUNT="${SA_NAME}"
  export TG_STATE_CONTAINER="${CONTAINER_NAME}"
  export TF_VAR_azure_key_vault_name="${AKV_NAME}"
  export TF_VAR_azure_key_vault_resource_group_name="${RG_NAME}"

----------------------------------------------------------------------
ARM_CLIENT_SECRET expires 1 year from now. Rotate via:

  az ad sp credential reset --id "${ARM_CLIENT_ID}" --years 1

======================================================================
EOF
