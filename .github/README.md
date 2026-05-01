# .github/

GitHub-side config for this repo — currently just the Actions workflow under `workflows/`.

| File | Workflow name | What it does |
|---|---|---|
| `workflows/terraform-flink.yml` | `terraform-flink` | Runs `terragrunt run-all <action>` against `terraform/live/<stack>`. `action` ∈ {plan, apply, destroy}, `stack` ∈ {dev, uat, prd}. |

Triggers:

- **`pull_request`** on changes to `terraform/**`, `tools/**`, or the workflow itself — defaults to `plan` against the `dev` stack.
- **`workflow_dispatch`** — pick `stack` and `action` from the Actions UI.

State backend: **Azure Storage** (`azurerm`). Auth to Azure: **OIDC / Workload Identity Federation** — the Entra app registration has no client secret. Instead, federated credentials on the app trust GitHub Actions OIDC tokens for `refs/heads/main` and `pull_request`. CI exchanges the short-lived GitHub-issued JWT for an Azure access token at run time. Nothing rotates, nothing leaks if a workflow log spills.

Confluent admin + Flink credentials are pulled from **Azure Key Vault** at plan/apply time — they never enter Terraform state, GitHub secrets, or CI environment variables. The same SP authenticates to the state storage account and reads the AKV secrets.

The bootstrap script `tools/bootstrap-azure-state.sh` provisions the state storage account, the app registration + SP (passwordless), the federated credentials, and the AKV (with RBAC granted to the SP) in one shot. After it runs, you populate the AKV with four secrets (the Confluent API keys you got from Confluent Cloud) and paste six values into GitHub.

## Repository secrets

Set at **repo → Settings → Secrets and variables → Actions → Repository secrets**.

### Azure (state backend auth + AKV reads)

| Name | Maps to env var | Purpose |
|---|---|---|
| `ARM_TENANT_ID` | `ARM_TENANT_ID` | Entra tenant of the target Azure subscription. |
| `ARM_SUBSCRIPTION_ID` | `ARM_SUBSCRIPTION_ID` | Subscription that hosts the state SA + AKV. |
| `ARM_CLIENT_ID` | `ARM_CLIENT_ID` | App ID of the service principal (e.g. `sp-flink-tf-state-rw`). |

**No `ARM_CLIENT_SECRET`** — auth is via OIDC. The workflow sets `ARM_USE_OIDC=true` and the azurerm SDK exchanges the GitHub OIDC token (issued because the workflow has `permissions: id-token: write`) for an Azure access token. The federated credentials on the app registration determine which workflows are trusted (subjects: `repo:<owner>/<repo>:ref:refs/heads/main` and `repo:<owner>/<repo>:pull_request`).

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

OIDC is GitHub-Actions-only — locally you authenticate as your own Azure user via `az login`. Your user needs **`Storage Blob Data Contributor` on the state SA** plus **`Key Vault Secrets User` (or Secrets Officer) on the AKV**. The bootstrap script grants you `Key Vault Secrets Officer` automatically when you run it as the signed-in user; storage RBAC for your user has to be granted separately if you want local apply rights.

```bash
az login
az account set --subscription "<sub-id>"

set -a; source .env.azure; set +a   # state-location vars only — see below

bash tools/install.sh
export PATH="$(pwd)/tools/bin:$PATH"

cd terraform/live/dev
terragrunt run-all plan
terragrunt run-all apply
terragrunt run-all destroy
```

`.env.azure` (gitignored) holds **state-location values only** — no auth values, since `az login` provides the credentials. The bootstrap script prints these:

```bash
export TG_STATE_RESOURCE_GROUP="rg-flink-tf-state"
export TG_STATE_STORAGE_ACCOUNT="<sa-name>"
export TG_STATE_CONTAINER="tfstate"
export TF_VAR_azure_key_vault_name="<akv-name>"
export TF_VAR_azure_key_vault_resource_group_name="<akv-rg>"
```

`ARM_USE_OIDC` is intentionally *not* set locally — `root.hcl` defaults it to `false` so the backend falls through to `az login`. Setting it locally would make the backend look for an OIDC token that doesn't exist outside GitHub Actions.
