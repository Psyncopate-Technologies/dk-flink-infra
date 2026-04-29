# .github/

GitHub-side config for this repo — currently just the Actions workflow under `workflows/`.

| File | Workflow name | What it does |
|---|---|---|
| `workflows/terraform-flink.yml` | `terraform-flink-plan` | Runs `terragrunt plan --all` against `terraform/live/<stack>`. Plan-only — apply/destroy are not exposed until a remote state backend is wired up. |

Triggers:

- `pull_request` on changes to `terraform/**`, `tools/**`, or the workflow itself — gives reviewers a plan diff against the dev stack.
- `workflow_dispatch` with a `stack` input (`dev` / `uat` / `prd`).

The workflow installs pinned Terraform + Terragrunt via `tools/install.sh` (versions in `tools/versions.env`) and runs the same commands you'd run locally.

## Repository secrets

Set at **repo → Settings → Secrets and variables → Actions → Repository secrets**.

| Name | Maps to env var | Purpose |
|---|---|---|
| `CONFLUENT_CLOUD_API_KEY` | `TF_VAR_confluent_cloud_api_key` | Cloud-scoped admin key — manages compute pools, environments. |
| `CONFLUENT_CLOUD_API_SECRET` | `TF_VAR_confluent_cloud_api_secret` | Cloud-scoped admin secret. |
| `CONFLUENT_FLINK_API_KEY` | `TF_VAR_confluent_flink_api_key` | Flink-scoped key — owned by the service account in `flink-config.json`. Used by the statements stack to submit statements. |
| `CONFLUENT_FLINK_API_SECRET` | `TF_VAR_confluent_flink_api_secret` | Flink-scoped secret. |

The two Flink-scoped values are the ones currently expected to come from Azure Key Vault in the long term; for now they live as GitHub secrets. The cloud-scoped key is admin-level and should be a service-account key with the minimum role bindings to manage Flink compute pools.

Non-secret values (`organization_id`, `environment_id`, `service_account_id`, region, pool sizing) live in `terraform/live/<stack>/flink-config.json` — not sensitive, version-controlled deliberately.

## Local CLI equivalent

From the repo root:

```bash
bash tools/install.sh
export PATH="$(pwd)/tools/bin:$PATH"

export TF_VAR_confluent_cloud_api_key="<cloud-key>"
export TF_VAR_confluent_cloud_api_secret="<cloud-secret>"
export TF_VAR_confluent_flink_api_key="<flink-key>"
export TF_VAR_confluent_flink_api_secret="<flink-secret>"

cd terraform/live/dev
terragrunt plan --all
```

## What's intentionally missing

- **Remote state backend.** `terraform/live/root.hcl` still uses the local backend, so apply from CI would create resources whose state is then discarded. Once a backend is decided (Azure Storage, S3, Terraform Cloud, etc.), add an apply job here gated on `workflow_dispatch` + an environment with required reviewers.
- **uat / prd stacks.** Only `dev/` exists today; `workflow_dispatch` already lists `uat` and `prd` so adding them later just needs the directory.
- **Confluent CLI / Python tooling.** The reference repo installs both for ad-hoc scripts. This repo doesn't use them yet — add to `tools/install.sh` if needed.
