# .github/

GitHub-side config for this repo — currently just the Actions workflow under `workflows/`.

| File | Workflow name | What it does |
|---|---|---|
| `workflows/terraform-flink.yml` | `terraform-flink` | Runs `terragrunt run-all <action>` against `terraform/live/<stack>`. `action` ∈ {plan, apply, destroy}, `stack` ∈ {dev, uat, prd}. |

Triggers:

- **`pull_request`** on changes to `terraform/**`, `tools/**`, or the workflow itself — defaults to `plan` against the `dev` stack.
- **`workflow_dispatch`** — pick `stack` and `action` from the Actions UI.

State backend: **Azure Storage** (`azurerm`). Auth to Azure: service principal + client secret (no OIDC). Confluent admin + Flink credentials are pulled from **Azure Key Vault** at plan/apply time — they never enter Terraform state, GitHub secrets, or CI environment variables. The same SP authenticates to the state storage account and reads the AKV secrets.

The bootstrap script `tools/bootstrap-azure-state.sh` provisions the state storage account, the SP, and the AKV (with RBAC granted to the SP) in one shot. After it runs, you populate the AKV with four secrets (the Confluent API keys you got from Confluent Cloud) and paste seven values into GitHub.

## Repository secrets

Set at **repo → Settings → Secrets and variables → Actions → Repository secrets**.

### Azure (state backend auth + AKV reads)

| Name | Maps to env var | Purpose |
|---|---|---|
| `ARM_TENANT_ID` | `ARM_TENANT_ID` | Entra tenant of your Psyncopate Azure subscription. |
| `ARM_SUBSCRIPTION_ID` | `ARM_SUBSCRIPTION_ID` | Subscription that hosts the state SA + AKV. |
| `ARM_CLIENT_ID` | `ARM_CLIENT_ID` | App ID of the service principal `sp-flink-tf-state-rw`. |
| `ARM_CLIENT_SECRET` | `ARM_CLIENT_SECRET` | Client secret for the SP. **Expires 1 year from creation — rotate before then.** |

### State backend location

| Name | Maps to env var | Purpose |
|---|---|---|
| `TG_STATE_RESOURCE_GROUP` | `TG_STATE_RESOURCE_GROUP` | Resource group containing the state SA. |
| `TG_STATE_STORAGE_ACCOUNT` | `TG_STATE_STORAGE_ACCOUNT` | Globally-unique SA name printed by the bootstrap script. |
| `TG_STATE_CONTAINER` | `TG_STATE_CONTAINER` | Blob container name (defaults to `tfstate`). |

## Repository variables

Set at **repo → Settings → Secrets and variables → Actions → Variables**. AKV identifiers aren't secrets, so they go here.

| Name | Maps to env var | Purpose |
|---|---|---|
| `AZURE_KEY_VAULT_NAME` | `TF_VAR_azure_key_vault_name` | AKV holding the four Confluent secrets. |
| `AZURE_KEY_VAULT_RESOURCE_GROUP_NAME` | `TF_VAR_azure_key_vault_resource_group_name` | RG containing the AKV. |

## AKV secrets — set inside the vault, NOT in GitHub

Populated once via `az keyvault secret set` (the bootstrap script prints the exact commands). `terraform/live/root.hcl` reads these by exact name:

| AKV secret name | Holds | Used by |
|---|---|---|
| `confluent-admin-key` | Confluent Cloud admin API key | `provider "confluent" { cloud_api_key = ... }` |
| `confluent-admin-secret` | Cloud admin API secret | `provider "confluent" { cloud_api_secret = ... }` |
| `confluent-flink-key` | Flink-region-scoped API key | `provider "confluent" { flink_api_key = ... }` (statements inherit) |
| `confluent-flink-secret` | Flink-region-scoped API secret | `provider "confluent" { flink_api_secret = ... }` (statements inherit) |

Rotation = update the AKV secret value. The next `terragrunt plan` reads the new value automatically — no code change, no GitHub-secret update.

Non-secret values (`organization_id`, `environment_id`, `service_account_id`, region, pool sizing) live in `terraform/live/<stack>/flink-config.json` — version-controlled deliberately.

## Local CLI equivalent

Local execution uses the same Azure backend + AKV, so state writes go to the same SA and secret reads hit the same vault. Two auth options for local:

**(a) Use the SP creds** (mirrors CI exactly):

```bash
set -a; source .env.azure; set +a   # paste bootstrap output into .env.azure (gitignored)

bash tools/install.sh
export PATH="$(pwd)/tools/bin:$PATH"

cd terraform/live/dev
terragrunt run-all plan
terragrunt run-all apply
terragrunt run-all destroy
```

**(b) Use your own Azure user** (no SP creds locally; just `az login`):

```bash
az login
az account set --subscription "<sub-id>"

export TG_STATE_RESOURCE_GROUP="rg-flink-tf-state"
export TG_STATE_STORAGE_ACCOUNT="<sa-name>"
export TG_STATE_CONTAINER="tfstate"
export TF_VAR_azure_key_vault_name="<akv-name>"
export TF_VAR_azure_key_vault_resource_group_name="<akv-rg>"

cd terraform/live/dev
terragrunt run-all plan
```

For (b) your Azure user needs both `Storage Blob Data Contributor` on the SA **and** `Key Vault Secrets User` on the AKV — the bootstrap script grants you `Key Vault Secrets Officer` (a superset) automatically when you run it as the signed-in user.
