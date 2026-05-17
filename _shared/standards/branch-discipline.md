---
name: Branch Discipline Standard
description: Per-project branch policy contract consumed by branch discipline gates. Defines the policy namespace, env var names, manager config doctor, and user-controlled bypasses.
type: standard
schema_version: 1
---

# Branch discipline

Studio branch behavior is project policy, not assistant memory. The canonical
policy is the `branch_policy` namespace in project feature config. Enforcement
surfaces read the same persisted values, then fall back to documented defaults
when a project has not written a value yet.

## Core invariants

1. **Local base branches are mirrors, not work branches.** No commits land on
   `main`, `master`, `trunk`, `develop`, or any branch configured as a
   protected base via `is_protected_branch` (`scripts/lib-paths.sh`) or via
   the per-project release-branch pattern. Pull, then fast-forward; never
   commit directly.
2. **Feature branches do not merge into other feature branches.** Dependent
   work rebases or retargets onto the integration base. The merge-commit
   audit lives in `feature_branch_policy_evaluate`
   (`scripts/lib-feature-branch-policy.sh`).
3. **Feature PRs land on the configured merge target.** When
   `STUDIO_BRANCH_POLICY_MERGE_TARGET_TO_MAIN` is truthy, `pr-merge-finalize`
   refuses to merge a PR whose base ref is not the project's canonical
   integration branch.
4. **Target project PRs are not auto-merged by default.** For PRs whose GitHub
   base repository is not the studio repository, reviewer/autopilot flows may
   create and approve the PR but must stop before `gh pr merge`. A human merges
   the target repo PR unless the user explicitly unlocks auto-merge with
   `pr_policy.target_repo_auto_merge` or a one-shot approved override.

## Per-project policy file

`manager-feature-config` writes settings to
`$STUDIO_HOME/<project>/config/features.env` as `STUDIO_*='value'` lines. The
following settings participate in branch discipline:

| Setting | Policy field | Consumed by |
|---|---|---|
| `STUDIO_BRANCH_POLICY_SCHEMA_VERSION` | `schema_version` | manager config doctor |
| `STUDIO_BRANCH_POLICY_DEFAULT_BASE` | `default_base` | manager config, branch workflow, pre-commit, pr-merge-finalize |
| `STUDIO_BRANCH_POLICY_RELEASE_BRANCH_PATTERN` | `release_branch_pattern` | manager config, branch workflow, pre-commit |
| `STUDIO_BRANCH_POLICY_ALLOW_FEATURE_OFF_FEATURE` | `allow_feature_off_feature` | plan-chain and work-chain stacked-parent checks |
| `STUDIO_BRANCH_POLICY_MERGE_TARGET_TO_MAIN` | `merge_target_to_main` | pr-merge-finalize |
| `STUDIO_BRANCH_POLICY_WORKTREE_GC_SCOPE` | `worktree_gc_scope` | Studio-owned worktree cleanup |
| `STUDIO_BRANCH_POLICY_WORKTREE_DISK_BUDGET_MB` | `worktree_disk_budget_mb` | Studio-owned worktree cleanup |
| `STUDIO_TARGET_REPO_AUTO_MERGE` | `pr_policy.target_repo_auto_merge` | pr-merge-finalize target-repo auto-merge lock |

Legacy release branch settings are still supported:

| Legacy setting | Canonical policy field |
|---|---|
| `STUDIO_RELEASE_BRANCH_DEFAULT_BASE` | `default_base` |
| `STUDIO_RELEASE_BRANCH_PATTERN` | `release_branch_pattern` |

The manager config command lazily creates missing policy fields and writes the
legacy aliases when the canonical release fields change. Consumers source the
file when present and fall back to the same defaults as manager config.

## Read path

Shell scripts use `scripts/lib-feature-branch-policy.sh` helpers for default
branch, release pattern, booleans, and worktree cleanup thresholds. The helper
library reads project feature config when available and keeps callers from
hand-rolling `$HOME/.dev-studio` paths.

Branch-policy doctor is the first debugging step when branch behavior is
surprising:

```bash
scripts/manager-feature-config.sh [--project <slug>] doctor branch_policy
```

The doctor identifies malformed policy, missing lazy migration, conflicts
between the branch-policy namespace and legacy release-branch aliases, and
branch patterns that would produce invalid refs before a downstream gate fails
closed.

## Override

`STUDIO_BYPASS_BRANCH_POLICY=1` is the user-controlled emergency override that
suppresses every branch-discipline gate documented here. Each gate that honors
the bypass must:

- mention the override in its error message,
- print a `warning:` line on stderr when the bypass is set, so the audit trail
  shows the intentional skip,
- record the bypass in any event/telemetry emitted by the surface.

Surface-specific bypasses still apply for backwards compatibility:

| Surface | Surface-specific bypass | Unified bypass |
|---|---|---|
| pre-commit base-branch guard | `STUDIO_BYPASS_MAIN_COMMIT_GUARD=1` | `STUDIO_BYPASS_BRANCH_POLICY=1` |
| pr-merge-finalize merge-commit gate | `STUDIO_BYPASS_FEATURE_MERGE_COMMIT_GATE=1` | `STUDIO_BYPASS_BRANCH_POLICY=1` |
| pr-merge-finalize merge-target gate | none | `STUDIO_BYPASS_BRANCH_POLICY=1` |
| pr-merge-finalize target-repo auto-merge lock | `STUDIO_TARGET_REPO_AUTO_MERGE=1`, or `--allow-target-repo-auto-merge --user-approved-bypass <github-url>` | none |

Assistants must not set the bypass on their own initiative; it is the user's
lever per the rule in CLAUDE.md §"Where workflow rules live".

## Implementation pointers

- `scripts/lib-feature-branch-policy.sh` — shared policy reader and
  merge-commit evaluator.
- `scripts/manager-feature-config.sh` — writes and doctors the branch-policy
  namespace.
- `scripts/manager-release-branch.sh` — uses the release branch policy for
  status, prepare, sync, and PR preflight.
- `scripts/pr-merge-finalize.sh` — applies PR merge-commit and merge-target
  gates before invoking GitHub.
- `.githooks/pre-commit` — applies the base-branch guard.

## Related

- `CLAUDE.md` §"Worktree protocol" — interactive sessions never edit the main
  checkout directly; the pre-commit guard is the safety net behind the
  worktree discipline.
- `REVIEW.md` — pulls in this standard for reviewer guidance.
