---
name: Feature Config Contract
description: Project-scoped Studio feature config contract, including the branch_policy namespace and manager config doctor expectations.
type: contract
schema_version: 1
---

# Feature Config Contract

Project-scoped Studio feature configuration lives in:

```text
~/.dev-studio/<project>/config/features.env
```

The file is owned by `scripts/manager-feature-config.sh`. Values are written as
single-quoted shell literals and may be sourced by trusted Studio scripts.

## Branch Policy Namespace

`branch_policy` is the canonical namespace for branch-discipline settings. It is
persisted as environment keys so shell entrypoints can read the same values:

| Setting | Env key | Default |
|---|---|---|
| `branch_policy.schema_version` | `STUDIO_BRANCH_POLICY_SCHEMA_VERSION` | `1` |
| `branch_policy.default_base` | `STUDIO_BRANCH_POLICY_DEFAULT_BASE` | `main` |
| `branch_policy.release_branch_pattern` | `STUDIO_BRANCH_POLICY_RELEASE_BRANCH_PATTERN` | `release/{version}` |
| `branch_policy.allow_feature_off_feature` | `STUDIO_BRANCH_POLICY_ALLOW_FEATURE_OFF_FEATURE` | `0` |
| `branch_policy.merge_target_to_main` | `STUDIO_BRANCH_POLICY_MERGE_TARGET_TO_MAIN` | `1` |
| `branch_policy.worktree_gc_scope` | `STUDIO_BRANCH_POLICY_WORKTREE_GC_SCOPE` | `project` |
| `branch_policy.worktree_disk_budget_mb` | `STUDIO_BRANCH_POLICY_WORKTREE_DISK_BUDGET_MB` | `10240` |
| `pr_policy.target_repo_auto_merge` | `STUDIO_TARGET_REPO_AUTO_MERGE` | unset / `0` |

`merge_target_to_main` is a legacy field name for the mainline-source gate:
when truthy, only release and hotfix heads may merge into `main`, `master`,
`trunk`, or `develop`. Boolean values are normalized to `1` or `0` by the
manager config command.
`worktree_gc_scope` is one of `project`, `runtime`, or `off`.

## Lazy Elicitation And Migration

The branch-policy namespace is created idempotently by:

```bash
scripts/manager-feature-config.sh [--project <slug>] get branch_policy
scripts/manager-feature-config.sh [--project <slug>] doctor branch_policy
scripts/manager-feature-config.sh [--project <slug>] list
```

Existing configs that only contain the legacy release-branch keys are upgraded
without manual edits:

- `STUDIO_RELEASE_BRANCH_DEFAULT_BASE` seeds `branch_policy.default_base`
- `STUDIO_RELEASE_BRANCH_PATTERN` seeds `branch_policy.release_branch_pattern`

The legacy keys remain write-through aliases for compatibility with older
release-branch entrypoints until those consumers migrate.

## Doctor

`scripts/manager-feature-config.sh doctor branch_policy` validates:

- schema version is `1`
- branch names and release patterns are syntactically valid
- release patterns contain `{version}`
- boolean settings are parseable
- worktree GC scope is supported
- disk budget is a positive integer
- legacy release aliases do not conflict with the branch-policy values

The command exits non-zero when validation fails. `doctor` with no namespace
checks the branch policy and existing feature gates.
