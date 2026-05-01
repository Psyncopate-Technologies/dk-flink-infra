# DKP onboarding guide

End-to-end setup from a freshly-cloned repo to a deployed Flink pipeline. Walk through phases 2–6 in order. Phase 1 (Azure storage account, service principal, AKV) is assumed already done as part of separate Azure platform setup — see `tools/bootstrap-azure-state.sh` if you need to provision those resources.

By the end of this guide:

- Confluent Cloud has the right service accounts + RBAC + API keys, and AKV holds the four secrets the pipeline reads.
- GitHub has the repo secrets + variables the workflow needs.
- `flink-config.json` is filled in for each environment.
- The first `apply` runs successfully in dev (and you know how to do uat / prd).

---

## Phase 2 — Confluent Cloud setup

### 2.1 Identify or create environments

Confluent Cloud organizes resources into **environments**. DKP should have at minimum one env per stage:

- `dkp-dev` (or similar)
- `dkp-uat`
- `dkp-prd`

If they don't exist yet, create them in **Confluent Cloud UI → Environments → + Add environment**.

Capture each environment's ID — looks like `env-XXXXX`. You'll paste these into `flink-config.json` later.

Also note the **organization ID** (same across all envs in a single org). Confluent UI → top-right account menu → "Organization ID". Looks like a UUID.

### 2.2 Identify or create service accounts

Recommended: **one service account per environment**, e.g. `dkp-flink-dev`, `dkp-flink-uat`, `dkp-flink-prd`. Each gets distinct API keys and RBAC scoped to its own env.

Acceptable alternative for simpler setups: a single `dkp-flink-admin` SA used across all envs.

In Confluent UI → "Accounts & access" → Service accounts → + Add service account.

Capture each SA's ID (looks like `sa-XXXXX`).

### 2.3 Grant RBAC on each service account

For each SA (per environment), grant these role bindings. Replace `<sa-id>`, `<env-id>`, `<cluster-id>`, `<sr-cluster-id>` accordingly. Run via the Confluent CLI (or the equivalent in the UI):

```bash
# A) Compute pool admin — create / scale / delete the pool itself
confluent iam rbac role-binding create \
  --principal "User:<sa-id>" \
  --role FlinkAdmin \
  --environment <env-id>

# B) Submit Flink statements
confluent iam rbac role-binding create \
  --principal "User:<sa-id>" \
  --role FlinkDeveloper \
  --environment <env-id>

# C) Read source topics
confluent iam rbac role-binding create \
  --principal "User:<sa-id>" \
  --role DeveloperRead \
  --resource "Topic:*" \
  --kafka-cluster <cluster-id> \
  --environment <env-id>

# D) Write sink topics
confluent iam rbac role-binding create \
  --principal "User:<sa-id>" \
  --role DeveloperWrite \
  --resource "Topic:*" \
  --kafka-cluster <cluster-id> \
  --environment <env-id>

# E) Schema Registry — read source schemas + register sink schemas
confluent iam rbac role-binding create \
  --principal "User:<sa-id>" \
  --role DeveloperRead \
  --resource "Subject:*-value" \
  --schema-registry-cluster <sr-cluster-id> \
  --environment <env-id>

confluent iam rbac role-binding create \
  --principal "User:<sa-id>" \
  --role DeveloperWrite \
  --resource "Subject:*-value" \
  --schema-registry-cluster <sr-cluster-id> \
  --environment <env-id>

# F) CRITICAL — enable exactly-once writes via Kafka transactions
confluent iam rbac role-binding create \
  --principal "User:<sa-id>" \
  --role DeveloperWrite \
  --resource "TransactionalId:*" \
  --kafka-cluster <cluster-id> \
  --environment <env-id>
```

Skipping role (F) is a common cause of `Transactional Id authorization failed` errors at apply time. Don't skip it.

For tighter scoping (production-grade), replace `Topic:*` and `Subject:*` with specific topic prefixes (e.g. `Topic:dkp.*`) and `TransactionalId:*` with a Flink-specific prefix.

### 2.4 Issue API keys (two per service account)

Each SA needs **two distinct API keys** — they cover different operations:

| Key type | Scope | Used for |
|---|---|---|
| **Cloud API key** | `--resource cloud` | Managing compute pool resource via Terraform |
| **Flink API key** | `--resource <flink-region-id>` | Authorizing actual Flink statement submissions |

Issue them via CLI:

```bash
# Cloud API key
confluent api-key create \
  --service-account <sa-id> \
  --resource cloud \
  --description "DKP Flink Terraform — cloud admin for <env>"
# Output: { "key": "...", "secret": "..." } — capture both

# Flink API key (per region — usually the region of your Kafka cluster)
confluent api-key create \
  --service-account <sa-id> \
  --resource <flink-region-id> \
  --description "DKP Flink — statement submission for <env>"
# Output: { "key": "...", "secret": "..." } — capture both
```

Find your `flink-region-id` via `confluent flink region list`. It looks like `aws.us-east-2`.

### 2.5 Store the four secrets in AKV

Per environment, store all four credentials in your AKV (the one referenced by `AZURE_KEY_VAULT_NAME` in GitHub vars — see Phase 3). The repo's `root.hcl` reads them by these exact names:

```bash
az keyvault secret set --vault-name <akv-name> \
  --name confluent-admin-key   --value "<cloud-key>"
az keyvault secret set --vault-name <akv-name> \
  --name confluent-admin-secret --value "<cloud-secret>"
az keyvault secret set --vault-name <akv-name> \
  --name confluent-flink-key    --value "<flink-key>"
az keyvault secret set --vault-name <akv-name> \
  --name confluent-flink-secret --value "<flink-secret>"
```

**Important:** the secret names are hardcoded in `terraform/live/root.hcl`. If you want different names, update `root.hcl` to match — don't rename the AKV secrets.

If you're using one AKV for all envs, this is one set of four. If you want per-env credential isolation (recommended for production), use one AKV per env and set the GitHub vars per environment too.

---

## Phase 3 — GitHub repository configuration

### 3.1 Repository secrets

Set at **Settings → Secrets and variables → Actions → Secrets**.

Sensitive values that change per Azure setup:

| Secret name | What it is |
|---|---|
| `ARM_TENANT_ID` | Entra tenant ID for the Azure subscription |
| `ARM_SUBSCRIPTION_ID` | Subscription containing the state SA + AKV |
| `ARM_CLIENT_ID` | App ID of the service principal that auths to Azure |
| `ARM_CLIENT_SECRET` | Client secret for that SP. **Expires in 1 year — rotate before then** |
| `TG_STATE_RESOURCE_GROUP` | Resource group hosting the state SA |
| `TG_STATE_STORAGE_ACCOUNT` | Globally-unique state SA name |
| `TG_STATE_CONTAINER` | Blob container in the state SA (default `tfstate`) |

### 3.2 Repository variables

Set at **Settings → Secrets and variables → Actions → Variables**. AKV identifiers aren't secrets, so they go here.

| Variable name | What it is |
|---|---|
| `AZURE_KEY_VAULT_NAME` | Name of the AKV holding the four Confluent secrets |
| `AZURE_KEY_VAULT_RESOURCE_GROUP_NAME` | Resource group of that AKV |

### 3.3 Recommended repo settings

**Settings → General → Pull Requests → enable "Automatically delete head branches"**. After every PR merge, the source branch is auto-deleted. Keeps the branch list clean.

**Settings → Branches → Add rule for `main`** (recommended for production-grade governance):
- Require a PR before merging
- Require approval from at least 1 reviewer
- Require status checks to pass (the workflow's plan job)

---

## Phase 4 — Configure each environment's `flink-config.json`

Each environment has its own config file at `terraform/live/<env>/flink-config.json`. Templates ship with `TODO-*` placeholders.

For each env (dev, uat, prd), replace the placeholders:

```json
{
  "_comment": "<env> environment Flink configuration. ...",

  "organization_id":     "<DKP org UUID>",
  "environment_id":      "<env-XXXXX for this stage>",
  "service_account_id":  "<sa-XXXXX for this stage>",

  "compute_pool": {
    "display_name": "dkp-flink-<env>-pool",
    "cloud":        "AWS",
    "region":       "us-east-2",
    "max_cfu":      <5|10|20>
  },

  "statements": {
    "<your_statement_key>": {
      "name": "<your-statement-name>",
      "sql": "INSERT INTO `target.topic` SELECT * FROM `source.topic`",
      "properties": {
        "sql.current-catalog":  "<env-display-name>",
        "sql.current-database": "<kafka-cluster-display-name>"
      },
      "stopped": false
    }
  }
}
```

Field-by-field reminders:

| Field | Notes |
|---|---|
| `organization_id` | Same value across dev/uat/prd in a single Confluent org |
| `environment_id` | Distinct per env (env-XXXXX) |
| `service_account_id` | Distinct per env if using per-stage SAs |
| `compute_pool.cloud` | MUST match the Kafka cluster's cloud (AWS / AZURE / GCP) |
| `compute_pool.region` | MUST match the cluster's region |
| `compute_pool.max_cfu` | Sizing per env. Defaults: dev=5, uat=10, prd=20 |
| `statements` | Map keyed by your local identifier. Each entry: name, sql, properties, stopped |

**SQL gotchas worth knowing:**

- **Backtick-quote topic names that contain dots, hyphens, or special characters.** Without backticks, Flink parses dots as `catalog.database.table` separators and fails to find the table.
- **Target topics must exist before INSERT INTO** can write to them. Either pre-create with the right schema, or use `CREATE TABLE <target> AS SELECT ...` (CTAS) which creates the target topic + schema in one go.
- **Avoid non-deterministic functions** (`NOW()`, `RAND()`, `CURRENT_TIMESTAMP`) — they break restart-safety. Use event-time columns from the source instead.
- **`sql.current-catalog`** = environment **display name** (not env-XXXXX ID). **`sql.current-database`** = Kafka cluster **display name**. Both are visible in the Confluent UI.

For lifecycle management of statements (stop / resume / destroy), see `docs/scoped-operations.md`.

---

## Phase 5 — First apply

### 5.1 Plan first

Trigger the workflow with **plan** to validate config before any infra changes:

> **Repo → Actions → terraform-flink → Run workflow → branch: `main`, stack: `dev`, action: `plan`**

Expected output in the workflow logs:

```
[compute-pool] Plan: 1 to add, 0 to change, 0 to destroy.
[statements]   Plan: N to add, 0 to change, 0 to destroy.   (where N = count of statements you defined)
```

If the plan errors, common causes:

| Error | Likely cause |
|---|---|
| `AKV ... not found` | `AZURE_KEY_VAULT_NAME` / `..._RESOURCE_GROUP_NAME` vars wrong, or SP lacks `Key Vault Reader` |
| `forbidden ... vaults/read` | SP is missing `Key Vault Reader` role on the AKV |
| `Secret 'confluent-admin-key' not found` | Secret name typo, or AKV not populated yet (Phase 2.5) |
| `invalid client secret` (AADSTS7000215) | `ARM_CLIENT_SECRET` wrong or rotated; Phase 3.1 secret needs updating |
| `column ... not found` | Likely a backtick issue on dotted topic names — see Phase 4 SQL gotchas |

### 5.2 Apply

Once plan looks right:

> **Repo → Actions → terraform-flink → Run workflow → stack: `dev`, action: `apply`**

Apply takes ~2 minutes for the compute pool + ~30 seconds per statement.

### 5.3 Repeat for UAT and PRD

Once dev is happy, repeat for `stack: uat` then `stack: prd`. Same plan-then-apply pattern.

For production specifically: do the apply via PR to gain audit trail and approval gating. See `docs/ci-cd-vs-local-cli.md`.

---

## Phase 6 — Verification + common pitfalls

### 6.1 Verification checklist

After each environment's apply:

- [ ] **Compute pool exists** — Confluent UI → environment → Flink → Compute Pools → see `dkp-flink-<env>-pool`, status = `PROVISIONED`
- [ ] **Each statement is `RUNNING`** — Flink → Statements. None should be `FAILED`, `DEGRADED`, or `STOPPED` (unless explicitly set `"stopped": true` in config)
- [ ] **Source topics are being consumed** — open a source topic's Messages tab; check that the offsets at the top are advancing in real time
- [ ] **Sink topics are receiving records** — open the sink topic's Messages tab; new records should appear
- [ ] **No statement-level errors** — click into each statement → Logs tab; should be empty or show only INFO-level entries
- [ ] **`Messages-behind` = 0** — on the statement detail page, this counter should be at or near zero (some lag during catchup is OK; sustained > 0 means a problem)
- [ ] **Terraform state is clean** — re-run plan; should report `No changes`

### 6.2 Common pitfalls

These caused real issues during initial setup; check them first when troubleshooting:

| Symptom | Cause | Fix |
|---|---|---|
| Plan hangs ~3 min on `Initializing the backend...` | Azure SDK trying MSI/IMDS first; failing back to client-secret slowly | Already mitigated — `root.hcl` passes SP creds explicitly. If recurring, verify ARM_USE_MSI / ARM_USE_OIDC are not set elsewhere |
| `Column 'X' not found in any table` | Either dotted column name needs backticks, OR target topic doesn't exist yet | Backtick the column / pre-create the target / use CTAS |
| `Transactional Id authorization failed` | Phase 2.3 step (F) skipped | Add `DeveloperWrite` on `TransactionalId:*` |
| `Table already exists` (on CTAS) | The target topic already exists from a previous run | Either delete the existing topic first, or switch SQL to `INSERT INTO` |
| Statement shows `RUNNING` but no records in sink | Probably a watermark / late-event issue, or RBAC missing on target topic | Check the Statement → Metrics tab for `numLateRecordsDropped`; verify `DeveloperWrite` on the target topic |
| Apply succeeds but next plan shows resource needs to be created | A 30-day-stopped statement was deleted by Confluent; or someone destroyed the pool out-of-band | Either re-create via apply, or import existing resource into state |
| `PR auto-runs plan but fails on AKV access` | `Key Vault Reader` role missing on the SP for the AKV | Grant role on AKV scope (separate from `Key Vault Secrets User`); both are needed |

### 6.3 Lifecycle operations going forward

For day-to-day operations after initial setup:

- **Add / change / remove statements** → edit `flink-config.json` → PR → review plan → merge → workflow_dispatch apply
- **Stop a statement temporarily (preserve checkpoint)** → set `"stopped": true` → PR → apply
- **Resume** → set `"stopped": false` → PR → apply (Flink resumes from saved offsets)
- **Destroy only statements (keep pool)** → see `docs/scoped-operations.md`
- **Tear everything down** → workflow_dispatch with `action: destroy`

For the architectural reasoning behind why most operations go through CI rather than direct CLI, see `docs/ci-cd-vs-local-cli.md`.

---

## Hand-off summary

When DKP is ready to take over:

- All four AKV secrets populated.
- Seven repo secrets + two repo variables set.
- All three `flink-config.json` files filled in.
- One successful plan + apply against dev (proves end-to-end auth + RBAC).
- A review of the four supporting docs in `docs/` for ongoing operations.

If onboarding stalls, the most likely culprit is one of the Phase 2 RBAC bindings or Phase 3 secrets/vars. Walk through them again carefully before deeper debugging.
