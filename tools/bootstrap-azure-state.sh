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

echo "[bootstrap] subscription=${AZURE_SUBSCRIPTION_ID}"
echo "[bootstrap] location=${LOCATION}"
echo "[bootstrap] rg=${RG_NAME} sa=${SA_NAME} container=${CONTAINER_NAME} sp=${SP_NAME}"
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

echo "[bootstrap] [5/6] creating service principal with RBAC..."
SCOPE="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}"
SP_JSON="$(az ad sp create-for-rbac \
  --name "${SP_NAME}" \
  --role "Storage Blob Data Contributor" \
  --scopes "${SCOPE}" \
  --years 1 \
  -o json)"

parse() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])" <<<"${SP_JSON}"; }

ARM_TENANT_ID="$(parse tenant)"
ARM_CLIENT_ID="$(parse appId)"
ARM_CLIENT_SECRET="$(parse password)"

echo "[bootstrap] [6/6] done."
echo
cat <<EOF
======================================================================
Save these as GitHub repo secrets (Settings → Secrets and variables →
Actions → Repository secrets). Each line is one secret.

  ARM_TENANT_ID              ${ARM_TENANT_ID}
  ARM_SUBSCRIPTION_ID        ${AZURE_SUBSCRIPTION_ID}
  ARM_CLIENT_ID              ${ARM_CLIENT_ID}
  ARM_CLIENT_SECRET          ${ARM_CLIENT_SECRET}
  TG_STATE_RESOURCE_GROUP    ${RG_NAME}
  TG_STATE_STORAGE_ACCOUNT   ${SA_NAME}
  TG_STATE_CONTAINER         ${CONTAINER_NAME}

----------------------------------------------------------------------
For local testing, paste these into a (gitignored) .env.azure and
\`set -a; source .env.azure; set +a\` before running terragrunt:

  export ARM_TENANT_ID="${ARM_TENANT_ID}"
  export ARM_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
  export ARM_CLIENT_ID="${ARM_CLIENT_ID}"
  export ARM_CLIENT_SECRET="${ARM_CLIENT_SECRET}"
  export TG_STATE_RESOURCE_GROUP="${RG_NAME}"
  export TG_STATE_STORAGE_ACCOUNT="${SA_NAME}"
  export TG_STATE_CONTAINER="${CONTAINER_NAME}"

----------------------------------------------------------------------
ARM_CLIENT_SECRET expires 1 year from now. Rotate via:

  az ad sp credential reset --id "${ARM_CLIENT_ID}" --years 1

======================================================================
EOF
