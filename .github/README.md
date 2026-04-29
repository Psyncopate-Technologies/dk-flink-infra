# .github/

GitHub-side config for this repo — currently just the Actions workflow under `workflows/`.

| File | Workflow name | What it does |
|---|---|---|
| `workflows/terraform-flink.yml` | `terraform-flink` | Runs `terragrunt run-all <action>` against `terraform/live/<stack>`. `action` ∈ {plan, apply, destroy}, `stack` ∈ {dev, uat, prd}. |

Triggers:

- **`pull_request`** on changes to `terraform/**`, `tools/**`, or the workflow itself — defaults to `plan` against the `dev` stack.
- **`workflow_dispatch`** — pick `stack` and `action` from the Actions UI.

State backend: **Azure Storage** (`azurerm`). Auth to Azure: service principal + client secret (no OIDC). The Terraform/Terragrunt bootstrap is in `tools/bootstrap-azure-state.sh` — run it once against your Azure subscription to provision the storage account + SP and get the secret values to paste in.

## Repository secrets

Set at **repo → Settings → Secrets and variables → Actions → Repository secrets**.

### Confluent Cloud

| Name | Maps to env var | Purpose |
|---|---|---|
| `CONFLUENT_CLOUD_API_KEY` | `TF_VAR_confluent_cloud_api_key` | Cloud-scoped admin key — manages compute pools, environments. |
| `CONFLUENT_CLOUD_API_SECRET` | `TF_VAR_confluent_cloud_api_secret` | Cloud-scoped admin secret. |
| `CONFLUENT_FLINK_API_KEY` | `TF_VAR_confluent_flink_api_key` | Flink-scoped key — owned by the service account in `flink-config.json`. Used by the statements stack to submit statements. |
| `CONFLUENT_FLINK_API_SECRET` | `TF_VAR_confluent_flink_api_secret` | Flink-scoped secret. |

The Flink-scoped key is expected to come from Azure Key Vault in the long term; for now it lives as a GitHub secret.

### Azure (state backend auth)

| Name | Maps to env var | Purpose |
|---|---|---|
| `ARM_TENANT_ID` | `ARM_TENANT_ID` | Entra tenant of your Psyncopate Azure subscription. |
| `ARM_SUBSCRIPTION_ID` | `ARM_SUBSCRIPTION_ID` | Subscription that hosts the Terraform state storage account. |
| `ARM_CLIENT_ID` | `ARM_CLIENT_ID` | App ID of the service principal `sp-flink-tf-state-rw`. |
| `ARM_CLIENT_SECRET` | `ARM_CLIENT_SECRET` | Client secret for the SP. **Expires 1 year from creation — rotate before then.** |

### State backend location

| Name | Maps to env var | Purpose |
|---|---|---|
| `TG_STATE_RESOURCE_GROUP` | `TG_STATE_RESOURCE_GROUP` | Resource group containing the state SA (e.g. `rg-flink-tf-state`). |
| `TG_STATE_STORAGE_ACCOUNT` | `TG_STATE_STORAGE_ACCOUNT` | Globally-unique SA name printed by the bootstrap script. |
| `TG_STATE_CONTAINER` | `TG_STATE_CONTAINER` | Blob container name (defaults to `tfstate`). |

Non-secret values (`organization_id`, `environment_id`, `service_account_id`, region, pool sizing) live in `terraform/live/<stack>/flink-config.json` — version-controlled deliberately.

## Local CLI equivalent

Local execution uses the same backend, so state writes go to the same Azure SA. Two auth options for local:

**(a) Use the SP creds** (mirrors CI exactly):

```bash
set -a; source .env.azure; set +a   # paste output of bootstrap script into .env.azure (gitignored)
export TF_VAR_confluent_cloud_api_key="<cloud-key>"
export TF_VAR_confluent_cloud_api_secret="<cloud-secret>"
export TF_VAR_confluent_flink_api_key="<flink-key>"
export TF_VAR_confluent_flink_api_secret="<flink-secret>"

bash tools/install.sh
export PATH="$(pwd)/tools/bin:$PATH"

cd terraform/live/dev
terragrunt run-all plan
terragrunt run-all apply
terragrunt run-all destroy
```

**(b) Use your own Azure user** (no SP creds locally; just `az login`):

```bash
az login                                          # browser login
az account set --subscription "<sub-id>"
export TG_STATE_RESOURCE_GROUP="rg-flink-tf-state"
export TG_STATE_STORAGE_ACCOUNT="<sa-name>"
export TG_STATE_CONTAINER="tfstate"
# ... TF_VAR_confluent_* exports as above ...

cd terraform/live/dev
terragrunt run-all plan
```

For (b) to work, your Azure user needs `Storage Blob Data Contributor` on the SA — by default the user who created the SA has Owner on the RG, which is sufficient.
