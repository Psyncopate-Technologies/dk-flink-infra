# `live/dev/` — Dev environment

Stage-specific Terragrunt stacks and config for the **dev** environment.

## Layout

```
dev/
├── flink-config.json          ← shared config: org_id, env_id, sa_id, compute pool sizing, statements map
├── compute-pool/
│   └── terragrunt.hcl         ← provisions the dev Flink compute pool (Group 1 in run-all)
└── statements/
    └── terragrunt.hcl         ← provisions Flink SQL statements on the pool (Group 2 — depends on compute-pool)
```

State files live in Azure Storage at `dev/compute-pool/terraform.tfstate` and `dev/statements/terraform.tfstate` (path derived from `path_relative_to_include()` in `../root.hcl`).

## How to apply

**Via CI (recommended):** Actions → terraform-flink → Run workflow → `stack: dev, action: <plan|apply|destroy>`.

**Locally:**
```bash
cd terraform/live/dev
terragrunt run-all init
terragrunt run-all plan
terragrunt run-all apply
```

## Configuration

Edit `flink-config.json`. Replace `TODO-*` placeholders with DKP dev-stage values. Field reference and SQL gotchas in [`../../../README.md`](../../../README.md). Step-by-step setup in [`../../../docs/dkp-onboarding.md`](../../../docs/dkp-onboarding.md).

## Per-statement lifecycle

To stop / resume / destroy individual statements without touching the compute pool, see [`../../../docs/scoped-operations.md`](../../../docs/scoped-operations.md).

## Notes specific to dev

- **`_` prefix filter** in `statements/terragrunt.hcl` has been **removed** (unlike uat/prd). Statement names starting with `_` are no longer silently dropped here.
- Dev's compute pool is sized at `max_cfu = 5` (minimum). Increase only if a single statement consistently saturates it.
