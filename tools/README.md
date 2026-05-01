# `tools/`

Helper scripts and pinned tool versions used by both CI and local invocations. Three files, two purposes: install pinned binaries, and bootstrap Azure prerequisites.

## Files

| File | Purpose | When to run |
|---|---|---|
| `versions.env` | Pinned versions of `terraform` and `terragrunt`. Single source of truth for both CI and local | Edit when bumping versions |
| `install.sh` | Downloads the pinned versions into `tools/bin/`. Idempotent (skips if already correct version) | Once per machine; CI runs every workflow execution |
| `bootstrap-azure-state.sh` | One-shot Azure setup: state resource group, storage account (with versioning + soft-delete), blob container, Key Vault, service principal, RBAC role assignments | **Once per Azure subscription**, by an admin with permission to create RGs, storage, AKV, and Entra ID app registrations |

## `tools/install.sh` — pinned tool installer

```bash
bash tools/install.sh
export PATH="$(pwd)/tools/bin:$PATH"
```

Reads `tools/versions.env` and downloads:

- `terraform` from `releases.hashicorp.com` (uses `TERRAFORM_VERSION`)
- `terragrunt` from GitHub releases (uses `TERRAGRUNT_VERSION`)

…into `tools/bin/`, which is gitignored. Idempotent — won't re-download if the binary already matches the pinned version. Cross-platform (macOS / Linux, x86_64 / arm64).

CI invokes this in every workflow run via `bash tools/install.sh` followed by adding `tools/bin/` to `GITHUB_PATH`.

## `tools/versions.env` — version pinning

```sh
TERRAFORM_VERSION=1.9.8
TERRAGRUNT_VERSION=0.71.5
```

Plain key-value file (sourceable as bash). Bumping versions = edit, commit, both CI and local pick up the new values automatically on the next `install.sh` run.

The `tools/versions.env` file is **explicitly allow-listed** in `.gitignore` — the broader `*.env` rule would otherwise hide it.

## `tools/bootstrap-azure-state.sh` — Azure prerequisites

This is the script that prepares the Azure side of the architecture so the rest of the repo can function. **Run once per Azure subscription**, before the first Terraform apply.

```bash
export AZURE_SUBSCRIPTION_ID="<your-subscription-uuid>"
bash tools/bootstrap-azure-state.sh
```

Optional environment overrides:

| Variable | Default | What it does |
|---|---|---|
| `AZURE_LOCATION` | `eastus2` | Region for all created resources |
| `RG_NAME` | `rg-flink-tf-state` | Resource group name |
| `SA_NAME` | `saflinkstate<5-digit-random>` | Storage account name (must be globally unique) |
| `CONTAINER_NAME` | `tfstate` | Blob container for state files |
| `SP_NAME` | `sp-flink-tf-state-rw` | Service principal display name |
| `AKV_NAME` | `kvflink<5-digit-random>` | Key Vault name (must be globally unique) |

What it creates (idempotent — re-running is safe and won't recreate existing resources):

1. **Resource group** for state + AKV
2. **Storage account** with TLS 1.2+, no public blob access, blob versioning, 30-day soft-delete
3. **Blob container** for Terraform state files
4. **Service principal** (Entra ID app + secret) — with `Storage Blob Data Contributor` on the SA scope
5. **Key Vault** in RBAC mode with purge-protection + 30-day soft-delete
6. **RBAC role assignments**:
   - SP gets `Storage Blob Data Contributor` on the SA (state read/write)
   - SP gets `Key Vault Secrets User` on the AKV (read secrets at plan/apply time)
   - SP gets `Key Vault Reader` on the AKV (read vault metadata)
   - The user running the script gets `Key Vault Secrets Officer` on the AKV (so they can populate secrets right after)

After completion, the script prints two blocks:

- **GitHub repo secrets** to set (`ARM_TENANT_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, etc.)
- **GitHub repo vars** to set (`AZURE_KEY_VAULT_NAME`, `AZURE_KEY_VAULT_RESOURCE_GROUP_NAME`)
- **`az keyvault secret set`** commands to populate the four Confluent secrets in the AKV

Copy these into a gitignored `.env.azure` file for local invocations, and into GitHub repo settings for CI.

### Prerequisites for running the bootstrap

- `az` CLI logged in (`az login`) as a user with:
  - Contributor (or Owner) on the target subscription
  - Permission to register Entra ID app registrations (some tenants restrict this)
- `python3` for parsing the SP JSON output (macOS + ubuntu-latest both ship with this)

If your tenant blocks app-registration creation, an admin will need to grant the right or run the SP-creation step on your behalf. See the `[5/8]` step in the script.

## What's *not* in here

- No tool for managing Confluent resources (those are managed by the Terraform code, not by helper scripts)
- No tool for populating AKV secrets (one-line `az keyvault secret set` commands; documented in `docs/dkp-onboarding.md` Phase 2.5)
- No tool for managing GitHub secrets/vars (set them via GitHub UI; documented in `.github/README.md` and `docs/dkp-onboarding.md` Phase 3)
