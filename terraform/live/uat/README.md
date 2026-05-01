# `live/uat/` — UAT environment

Stage-specific Terragrunt stacks and config for the **UAT** environment.

## Layout

```
uat/
├── flink-config.json          ← shared config (currently TODO-* placeholders — fill in before applying)
├── compute-pool/
│   └── terragrunt.hcl         ← provisions the UAT Flink compute pool
└── statements/
    └── terragrunt.hcl         ← provisions Flink SQL statements on the pool
```

State files live in Azure Storage at `uat/compute-pool/terraform.tfstate` and `uat/statements/terraform.tfstate`.

## How to apply

**Via CI (recommended):** Actions → terraform-flink → Run workflow → `stack: uat, action: <plan|apply|destroy>`.

**Locally:**
```bash
cd terraform/live/uat
terragrunt run-all init
terragrunt run-all plan
terragrunt run-all apply
```

## Configuration

`flink-config.json` ships with `TODO-*` placeholders. Replace them with DKP UAT-stage values before applying. See [`../../../docs/dkp-onboarding.md`](../../../docs/dkp-onboarding.md) Phase 4 for guidance.

## Promotion pattern

UAT is meant for pre-production validation of statements that have already been validated in dev. Typical flow:

1. Develop and prove a statement in `dev/` (`flink-config.json` change → PR → apply).
2. Once validated, promote to UAT by adding the same statement entry to `uat/flink-config.json` (with UAT-specific topic names if topics are stage-prefixed).
3. After UAT validation, repeat for `prd/`.

## Notes specific to UAT

- Default `max_cfu = 10` — moderately higher than dev to allow realistic load testing.
- The `_` prefix filter is **still present** in `statements/terragrunt.hcl` (we removed it only in dev). To remove it here, edit the locals block similarly to dev's.
