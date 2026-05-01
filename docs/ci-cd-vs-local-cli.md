# CI/CD pipeline vs local CLI — when to use which

The repo supports two paths for running terraform/terragrunt against the Flink infrastructure: the GitHub Actions workflow (`.github/workflows/terraform-flink.yml`) and direct `terragrunt` invocations from a developer's laptop. **Both paths exist for different reasons.** They are complementary, not redundant.

This doc explains what each path provides, when to use which, and the current gap that's worth closing for production-grade operations.

---

## Why CI/CD exists when local CLI works

A natural question once you've confirmed that local `cd terraform/live/dev/statements && terragrunt apply` does the job: why bother with the workflow at all? Five concrete reasons CI/CD provides that CLI alone doesn't:

| Property | Why CI/CD provides it | Why local CLI doesn't |
|---|---|---|
| **Audit trail** | Every workflow run is logged with: who triggered it, when, what action, what stack, what commit, full output — searchable in GitHub Actions for years | Local runs leave traces in shell history and `.terragrunt-cache`, lost when the laptop is wiped or the cache cleared |
| **Reproducibility** | Same Ubuntu runner, same pinned tool versions (`tools/versions.env`), same Azure auth, same state backend — every run is deterministic | Local environment varies — different OS, terraform versions, `az login` state, network conditions |
| **Authorization gating** | GitHub repo permissions decide who can trigger workflow_dispatch. Branch protection decides who can merge. Environment protection rules can require approval for production stacks | Anyone with the SP credentials + access to the laptop can run terraform unilaterally |
| **No "deployer's laptop" dependency** | If the engineer who knows how to deploy is on vacation, anyone with repo access can still trigger an apply via the Actions UI | Tied to whoever has credentials configured locally |
| **PR review enforces the change** | Every modification to infra has a documented diff that someone other than the author looked at | Local runs are unilateral — author writes, author runs, no second pair of eyes |
| **Single source of truth = main branch** | Whatever's deployed = whatever's in main. Easy to verify "what's currently in prod" by reading the JSON | Local state can drift; an engineer can apply something they never committed |
| **No race conditions on shared state** | Each workflow run holds the Azure blob lease for the duration; concurrent runs serialize naturally | Two engineers running terraform locally at the same time can corrupt state |
| **Compliance / regulatory posture** | DKP is a trading firm. Auditable, gated infra changes are a compliance requirement (SOX, FINRA-adjacent). CI/CD provides the evidence trail an auditor needs | Local CLI changes leave no auditable artifact; insufficient for regulated environments |

For a regulated trading firm, the audit-trail and authorization-gating properties alone are sufficient to mandate CI/CD as the primary path for production-affecting changes.

---

## Why local CLI exists when CI/CD works

Equally important: there are real use cases where CI/CD is too slow or too rigid, and CLI is the right tool.

| Use case | Why local matters |
|---|---|
| **Dev environment iteration** | "I'm experimenting with a new SQL, want to try it 5 times in a row." Faster than the PR cycle for throwaway dev work. Author = approver. |
| **Incident response** | "Production is down at 3am, statement is wedged, need to stop NOW." If CI itself is broken (GitHub down, Azure down, runner unavailable), local CLI is the break-glass. Documented in runbooks with reconciliation SLA. |
| **Exploration / debugging** | "I need to query the live state to understand what's happening." `terragrunt plan` locally tells you what would change without committing to anything. |
| **Pre-PR validation** | "Let me run `terragrunt run-all plan` before I open a PR to confirm my change is sane." Catches errors before reviewers waste time. |
| **State surgery** | Sometimes the state needs a `terraform import` or a `terraform state rm` that doesn't fit the GitOps model. Always followed by reconciliation back to git. |

CLI is *additive* to CI/CD — not a replacement.

---

## Decision matrix — which path for which operation

| Operation | Recommended path | Why |
|---|---|---|
| **Production apply / destroy** | **CI/CD only** | Compliance + audit + gating. Never run prod terraform locally. |
| **Production lifecycle changes** (stop/resume statement) | **CI/CD only** via PR + merge + apply | Operational change with audit trail; matches the GitOps pattern |
| **Production scale change** (max_cfu) | **CI/CD only** | Cost-affecting; review essential |
| **Dev / UAT applies** | CI/CD preferred; local OK for fast iteration | Compliance is lighter for non-prod; speed matters |
| **Incident response — emergency stop** | Local CLI break-glass | Speed > review during incidents. Reconciliation SLA: update main + redo via CI within e.g. 24h so the audit trail catches up |
| **Plan-only previewing** | Either | Local for fast feedback, CI for the official-on-PR preview |
| **State surgery** (`import`, `state rm`, manual recovery) | Local | Doesn't fit the declarative GitOps pattern. Always document afterward and reconcile to git. |
| **Routine dev iteration** (5 small changes in 10 min) | Local | PR cycle too slow for throwaway exploration |
| **Anything affecting shared resources across teams** | **CI/CD only** | Race conditions and audit are critical when multiple engineers are involved |

The dividing line: **changes someone else needs to see in `git log` go through CI/CD; ad-hoc operational work can use CLI**, with the implicit rule that anything CLI-driven against production must be reconciled back to git within a documented window.

---

## Current architectural gap — no partial-scope CI workflow yet

Right now the workflow only knows how to do `run-all` against a whole environment:

```yaml
# Current dispatch inputs
stack:  [dev, uat, prd]
action: [plan, apply, destroy]
```

This is sufficient for full-stack operations but doesn't expose **partial scope** (e.g. "destroy only the statements stack, leave the compute pool alone"). For partial operations, today's only path is local CLI:

```bash
cd terraform/live/dev/statements
terragrunt destroy
```

Which means partial-scope operations against production currently bypass the audit trail / gating that CI/CD provides. **That's a gap.**

The fix is documented in `docs/scoped-operations.md`: add a `scope` input to the workflow_dispatch, with options `[all, compute-pool, statements]`. Then:

- "Destroy only statements in dev via CI" becomes `stack: dev, scope: statements, action: destroy` in the dispatch UI — gated, audited, no `cd` needed.
- "Plan only the compute-pool stack" becomes `scope: compute-pool, action: plan`.

This is ~10 lines of YAML. Pending decision to wire it up.

For DKP's regulated-environment posture, **the `scope` input should be added before production stacks are wired up**, so partial operations against `prd` go through the audited CI path from day one.

---

## DKP-specific guidance summary

1. **Production work** — CI/CD only. PR + merge + workflow_dispatch. No exceptions during steady-state.
2. **Production incident response** — CLI break-glass with mandatory git reconciliation within 24h.
3. **Dev/UAT work** — either path; default to CI/CD for habit-building, fall back to CLI for speed.
4. **The `scope` input gap** — add it before production stacks come online. Minor effort, large compliance benefit.
5. **Document the break-glass procedure** — write down explicitly how an SRE should perform an emergency stop locally and what reconciliation steps follow. Without a documented break-glass, on-call engineers either freeze or freelance — neither is good.

---

## Related docs

- `docs/scoped-operations.md` — operational mechanics for partial scope (compute-pool only, statements only). Covers the imperative-vs-declarative tradeoff for "remove statements, keep pool" scenarios.
- `.github/README.md` — workflow inputs, secrets, vars reference. Day-to-day operator reference.
