# `live/prd/` — Production environment

Stage-specific Terragrunt stacks and config for **production**.

## Layout

```
prd/
├── flink-config.json          ← shared config (currently TODO-* placeholders — fill in before applying)
├── compute-pool/
│   └── terragrunt.hcl         ← provisions the PRD Flink compute pool
└── statements/
    └── terragrunt.hcl         ← provisions Flink SQL statements on the pool
```

State files live in Azure Storage at `prd/compute-pool/terraform.tfstate` and `prd/statements/terraform.tfstate`.

## ⚠️ Production guard-rails

**Production changes must always go through PR review.** Do not push directly to main for prd, do not run apply locally except for explicit incident-response break-glass scenarios. See [`../../../docs/ci-cd-vs-local-cli.md`](../../../docs/ci-cd-vs-local-cli.md) for the full rationale.

Recommended branch-protection rules on `main`:

- Require a PR before merging
- Require at least one reviewer approval
- Require the workflow's plan job to pass

## How to apply

**Via CI only for prd:** Actions → terraform-flink → Run workflow → `stack: prd, action: <plan|apply|destroy>`.

After merging a PR, trigger workflow_dispatch with `action: apply`. Verify the plan output before approving the run.

## Configuration

`flink-config.json` ships with `TODO-*` placeholders. Replace them with DKP production-stage values before applying. The PRD service account should be a separate identity from dev/uat (no shared credentials in production).

See [`../../../docs/dkp-onboarding.md`](../../../docs/dkp-onboarding.md) Phase 4 for guidance.

## Notes specific to PRD

- Default `max_cfu = 20` — adjust based on observed CFU utilization. Over-provisioning costs money; under-provisioning causes lag.
- The `_` prefix filter is **still present** in `statements/terragrunt.hcl`. To remove it here, edit the locals block similarly to dev's.
- Long-term `stopped: true` statements are deleted by Confluent after 30 days. For long pauses, prefer `terraform destroy` of just the statement entry (remove from JSON map) rather than leaving it stopped indefinitely.
