# Scoped operations — managing compute-pool and statements independently

The default `terragrunt run-all <action>` from `terraform/live/<env>/` operates on **both** stacks (compute-pool and statements) together. Sometimes you only want to act on one — for example, removing all statements while keeping the compute pool running, or resizing the pool without touching deployed statements. This doc covers how, when, and what to watch out for.

---

## The two stacks live in independent state files

```
terraform/live/dev/
├── compute-pool/   →  state at  dev/compute-pool/terraform.tfstate    (in Azure SA)
└── statements/     →  state at  dev/statements/terraform.tfstate
```

Acting on one does not touch the other's state. The dependency between them is one-directional (statements reads compute-pool's outputs at plan-time); destroying statements never affects the pool, and vice versa.

---

## Three ways to scope operations

### 1. Local: cd into the sub-stack

```bash
cd terraform/live/dev/statements
terragrunt destroy        # all statements gone, pool still running
terragrunt apply          # re-create from current flink-config.json
terragrunt plan
```

Works for any single stack. The simplest and most common path during development.

### 2. Local: run-all with exclude

From the env root, exclude one sub-stack from the run:

```bash
cd terraform/live/dev
terragrunt run-all destroy --terragrunt-exclude-dir=compute-pool
# (newer terragrunt syntax: --queue-exclude-dir=compute-pool)
```

Same end result as cd'ing into `statements`, but executed from the env root. Useful when you want to keep the run-all execution model but skip one stack.

### 3. CI: workflow scope input (proposed, not yet wired)

The current workflow has `stack` (`dev`/`uat`/`prd`) and `action` (`plan`/`apply`/`destroy`). Adding a third input — `scope` (`all`/`compute-pool`/`statements`) — gives the same flexibility from the Actions UI. Sketch:

```yaml
inputs:
  stack:    [dev, uat, prd]
  scope:    [all, compute-pool, statements]
  action:   [plan, apply, destroy]
```

With `scope=all`, the workflow runs `terragrunt run-all <action>` from the env directory (current behavior). With `scope=compute-pool` or `scope=statements`, it `cd`s into that sub-stack and runs plain `terragrunt <action>` (no run-all).

This is a ~10-line YAML change. Implement when needed.

---

## Imperative destroy vs. declarative apply

There are two semantically different ways to "remove all statements but keep the pool." Both end up with the same Confluent state, but they differ in audit trail and reproducibility.

### (a) Imperative — `terragrunt destroy` on the statements stack

```bash
cd terraform/live/dev/statements && terragrunt destroy
```

- Removes every `confluent_flink_statement.*` resource from Confluent and from state.
- The statements stack's state file becomes empty (the stack is still "initialized," just tracking zero resources).
- `flink-config.json` is unchanged. Re-applying via `terragrunt apply` recreates whatever's in that file.

### (b) Declarative — edit `flink-config.json`, then `terragrunt apply`

1. Edit `terraform/live/<env>/flink-config.json`. Either delete the statement entries from the `statements` map, or rename their keys with a leading `_` (which the terragrunt config filters out).
2. `cd terraform/live/<env>/statements && terragrunt apply`.
3. Terraform notices the statements no longer exist in the desired config and removes them.

Same end state on the Confluent side, but the **JSON is the source of truth** and the change is captured in `git log`.

### Which to use when

| Use case | Recommended |
|---|---|
| Permanent removal — "this app's pipeline is being decommissioned" | **(b) declarative** — version-controlled, reviewable, the JSON stays the canonical "what should be running" |
| Operational ad-hoc — "wipe statements to debug, re-apply in 10 min" | **(a) imperative destroy** — faster, no PR cycle |
| Cost pause — "scale down to zero for the weekend, restore Monday" | **(a) destroy** the statements stack, then re-apply on Monday from the unchanged config |
| One specific statement — "stop just this one runaway query" | `terragrunt destroy -target='confluent_flink_statement.statements["foo"]'`, or set `"stopped": true` on it in the config and re-apply |

General rule: if the change is something you'd want a teammate to see in `git log`, prefer **(b)**. If it's purely operational, **(a)** is faster.

---

## Cost note — destroying statements doesn't stop the pool's bill

The compute pool charges a **CFU base cost** while it exists, regardless of how many statements are running on it. At `max_cfu = 5` that's roughly $0.30/CFU/hr × 5 ≈ $36/day idle.

So **destroying statements alone does not save money** — the pool keeps running. To actually stop the bill, you need:

```bash
cd terraform/live/dev
terragrunt run-all destroy
```

…which destroys both stacks (statements first, then the pool) and zeroes the cost. Re-applying takes ~10 seconds for the pool plus statement-creation time. For weekend pauses on a non-prod env, this is usually the right move.

---

## Quick reference

| Goal | Command |
|---|---|
| Apply both stacks (initial setup or full re-apply) | `cd terraform/live/<env> && terragrunt run-all apply` |
| Plan both stacks | `cd terraform/live/<env> && terragrunt run-all plan` |
| Remove all statements, keep the pool | `cd terraform/live/<env>/statements && terragrunt destroy` |
| Remove just one statement | `cd terraform/live/<env>/statements && terragrunt destroy -target='confluent_flink_statement.statements["<key>"]'` |
| Pause one statement (without removing) | Set `"stopped": true` on it in `flink-config.json`, then `terragrunt apply` in `statements/` |
| Resize the pool only | Edit `compute_pool.max_cfu` in `flink-config.json`, then `terragrunt apply` in `compute-pool/` |
| Tear everything down (stop the bill) | `cd terraform/live/<env> && terragrunt run-all destroy` |
