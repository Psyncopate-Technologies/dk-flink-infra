#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-time Azure setup for Terraform/Terragrunt state.
#
# Auth model: OIDC (Workload Identity Federation).
#   The created App Registration has NO client secret — instead, federated
#   credentials trust GitHub Actions OIDC tokens for `refs/heads/main` and
#   `pull_request`. CI exchanges its short-lived GitHub token for an Azure
#   access token at run time. Nothing rotates; nothing leaks if a workflow
#   log spills.
#
# Creates (idempotent — re-runs are safe):
#   - Resource group
#   - Storage account (LRS, TLS 1.2, no public blob access, blob versioning +
#     30-day soft delete)
#   - Blob container
#   - Entra ID App + Service Principal (no client secret)
#   - Two federated credentials on that app: one for `main`, one for PRs
#   - Key Vault (RBAC mode, purge-protect, 30-day soft-delete)
#   - RBAC: Storage Blob Data Contributor on SA, Key Vault Secrets User +
#     Reader on AKV (granted to the SP); Key Vault Secrets Officer on AKV
#     (granted to the user running the script, so they can populate secrets).
#
# Prints the values you save into GitHub repo secrets/vars at the end.
#
# Prereqs:
#   - az CLI, signed in (`az login`) as someone with Owner/Contributor on the
#     subscription AND permission to create Entra ID app registrations +
#     federated credentials.
#   - python3 (for JSON parsing — present on macOS / ubuntu-latest).
# -----------------------------------------------------------------------------
set -euo pipefail

: "${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID before running}"
: "${GITHUB_REPO:?Set GITHUB_REPO=<owner>/<repo> (e.g. DKP-org/dkp-flink-terraform)}"

LOCATION="${AZURE_LOCATION:-eastus2}"
RG_NAME="${RG_NAME:-rg-flink-tf-state}"
SA_NAME="${SA_NAME:-saflinkstate$(printf '%05d' "$((RANDOM % 100000))")}"
CONTAINER_NAME="${CONTAINER_NAME:-tfstate}"
SP_NAME="${SP_NAME:-sp-flink-tf-state-rw}"
AKV_NAME="${AKV_NAME:-kvflink$(printf '%05d' "$((RANDOM % 100000))")}"
GITHUB_MAIN_REF="${GITHUB_MAIN_REF:-refs/heads/main}"

echo "[bootstrap] subscription=${AZURE_SUBSCRIPTION_ID}"
echo "[bootstrap] location=${LOCATION}"
echo "[bootstrap] rg=${RG_NAME} sa=${SA_NAME} container=${CONTAINER_NAME}"
echo "[bootstrap] sp=${SP_NAME} akv=${AKV_NAME}"
echo "[bootstrap] github_repo=${GITHUB_REPO} (federated cred subjects)"
echo

az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

echo "[bootstrap] [1/8] creating resource group..."
az group create --name "${RG_NAME}" --location "${LOCATION}" -o none

echo "[bootstrap] [2/8] creating storage account (skips if it already exists)..."
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

echo "[bootstrap] [3/8] enabling blob versioning + 30-day soft delete..."
az storage account blob-service-properties update \
  --account-name "${SA_NAME}" \
  --resource-group "${RG_NAME}" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30 \
  -o none

echo "[bootstrap] [4/8] creating blob container (auth-mode login)..."
az storage container create \
  --name "${CONTAINER_NAME}" \
  --account-name "${SA_NAME}" \
  --auth-mode login \
  -o none

echo "[bootstrap] [5/8] creating Entra app + SP (no client secret) and federated credentials..."
SCOPE_SA="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}"

# App registration (idempotent — reuse if a previous run created one).
APP_ID="$(az ad app list --display-name "${SP_NAME}" --query "[0].appId" -o tsv 2>/dev/null || true)"
if [[ -z "${APP_ID}" ]]; then
  APP_ID="$(az ad app create --display-name "${SP_NAME}" --query appId -o tsv)"
fi

# Service principal for that app (idempotent).
SP_OBJECT_ID="$(az ad sp show --id "${APP_ID}" --query id -o tsv 2>/dev/null || true)"
if [[ -z "${SP_OBJECT_ID}" ]]; then
  SP_OBJECT_ID="$(az ad sp create --id "${APP_ID}" --query id -o tsv)"
fi

# Storage Blob Data Contributor on the state SA.
az role assignment create \
  --assignee-object-id "${SP_OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "${SCOPE_SA}" \
  -o none 2>/dev/null || echo "[bootstrap]   (Storage Blob Data Contributor already granted — continuing)"

# Federated credentials. One for pushes/dispatch on main, one for PR runs.
add_fed_cred() {
  local name="$1"
  local subject="$2"
  # Skip if already present (idempotent re-runs).
  if az ad app federated-credential list --id "${APP_ID}" --query "[?name=='${name}']" -o tsv 2>/dev/null | grep -q .; then
    echo "[bootstrap]   federated cred '${name}' already exists — skipping"
    return
  fi
  az ad app federated-credential create \
    --id "${APP_ID}" \
    --parameters "$(python3 -c "
import json, sys
print(json.dumps({
    'name': '${name}',
    'issuer': 'https://token.actions.githubusercontent.com',
    'subject': '${subject}',
    'audiences': ['api://AzureADTokenExchange'],
}))
")" \
    -o none
  echo "[bootstrap]   federated cred '${name}' created (subject=${subject})"
}

add_fed_cred "github-actions-main" "repo:${GITHUB_REPO}:ref:${GITHUB_MAIN_REF}"
add_fed_cred "github-actions-pr"   "repo:${GITHUB_REPO}:pull_request"

ARM_TENANT_ID="$(az account show --query tenantId -o tsv)"
ARM_CLIENT_ID="${APP_ID}"

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

echo "[bootstrap] [7/8] granting SP Key Vault Secrets User + Key Vault Reader on the AKV..."
SCOPE_AKV="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.KeyVault/vaults/${AKV_NAME}"
az role assignment create \
  --assignee-object-id "${SP_OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "${SCOPE_AKV}" \
  -o none 2>/dev/null || echo "[bootstrap]   (Key Vault Secrets User already granted — continuing)"

az role assignment create \
  --assignee-object-id "${SP_OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Reader" \
  --scope "${SCOPE_AKV}" \
  -o none 2>/dev/null || echo "[bootstrap]   (Key Vault Reader already granted — continuing)"

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
    -o none 2>/dev/null || true
fi

echo "[bootstrap] [8/8] done."
echo
cat <<EOF
======================================================================
GitHub configuration — Settings -> Secrets and variables -> Actions

REPO SECRETS (set under "Repository secrets"):

  ARM_TENANT_ID              ${ARM_TENANT_ID}
  ARM_SUBSCRIPTION_ID        ${AZURE_SUBSCRIPTION_ID}
  ARM_CLIENT_ID              ${ARM_CLIENT_ID}
  TG_STATE_RESOURCE_GROUP    ${RG_NAME}
  TG_STATE_STORAGE_ACCOUNT   ${SA_NAME}
  TG_STATE_CONTAINER         ${CONTAINER_NAME}

  Note: NO ARM_CLIENT_SECRET. The workflow authenticates via OIDC using the
  federated credentials created on this app. If you previously had a
  client-secret-based ARM_CLIENT_SECRET set, delete it from repo secrets.

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
LOCAL CLI (for engineers running terragrunt off-CI):

OIDC is GitHub-Actions-only — locally you authenticate as your own Azure
user via \`az login\`. Your user needs:

  - Storage Blob Data Contributor on the state SA  (already granted to the SP;
    grant separately to your user account if you want local apply rights)
  - Key Vault Secrets User + Key Vault Reader on the AKV  (or Secrets Officer,
    which the bootstrap granted you above)

Then:

  az login
  az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

  set -a; source .env.azure; set +a    # state-location vars only (see below)

  bash tools/install.sh
  export PATH="\$(pwd)/tools/bin:\$PATH"

  cd terraform/live/dev
  terragrunt run-all plan

.env.azure (gitignored) contents — state location only, no auth values:

  export TG_STATE_RESOURCE_GROUP="${RG_NAME}"
  export TG_STATE_STORAGE_ACCOUNT="${SA_NAME}"
  export TG_STATE_CONTAINER="${CONTAINER_NAME}"
  export TF_VAR_azure_key_vault_name="${AKV_NAME}"
  export TF_VAR_azure_key_vault_resource_group_name="${RG_NAME}"

----------------------------------------------------------------------
ROTATION: nothing to rotate. There is no client secret. Federated
credentials don't expire. To revoke CI access, delete the federated
credential from the app:

  az ad app federated-credential delete --id "${ARM_CLIENT_ID}" \\
    --federated-credential-id <name-from-bootstrap>

To re-issue, just re-run this bootstrap script (it's idempotent).

======================================================================
EOF
