---
name: Branch Discipline Standard
description: Per-project branch policy contract consumed by the pre-commit base-branch guard and the pr-merge-finalize merge-target gate. Defines the policy file fields, env var names, the unified STUDIO_BYPASS_BRANCH_POLICY override, and the surface-specific bypasses kept for backwards compatibility.
type: standard
schema_version: 1
---

# Branch discipline

Canonical reference for the Studio's feature-branch lifecycle. Two enforcement
surfaces — pre-commit hook and PR finalize — read the per-project policy file
shipped by `manager-feature-config` (T-R001) and apply the rules below.

## Core invariants

1. **Local base branches are mirrors, not work branches.** No commits land on
   `main`, `master`, `trunk`, `develop`, or any branch configured as a
   protected base via `is_protected_branch` (`scripts/lib-paths.sh`) or via
   the per-project release-branch pattern. Pull, then fast-forward — never
   commit directly.
2. **Feature branches do not merge into other feature branches.** Dependent
   work rebases or retargets onto the integration base. The merge-commit
   audit lives in `feature_branch_policy_evaluate`
   (`scripts/lib-feature-branch-policy.sh`).
3. **Feature PRs land on the configured merge target.** When
   `STUDIO_BRANCH_POLICY_MERGE_TARGET_TO_MAIN` is truthy, `pr-merge-finalize`
   refuses to merge a PR whose base ref is not the project's canonical
   integration branch (`main` by default, overridable via
   `STUDIO_RELEASE_BRANCH_DEFAULT_BASE`).

## Per-project policy file

`manager-feature-config` writes settings to
`$STUDIO_HOME/<project>/config/features.env` as `STUDIO_*='value'` lines. The
following settings participate in branch discipline:

| Setting | Owner task | Consumed by |
|---|---|---|
| `STUDIO_RELEASE_BRANCH_DEFAULT_BASE` | T-R001 | pre-commit, pr-merge-finalize |
| `STUDIO_RELEASE_BRANCH_PATTERN` | T-R001 | pre-commit (extra base detection) |
| `STUDIO_BRANCH_POLICY_MERGE_TARGET_TO_MAIN` | T-R001 | pr-merge-finalize |

A consumer that needs the values sources the file when present and falls back
to the documented default when a setting is absent. Both the pre-commit hook
and `pr-merge-finalize` source the file through `lib-paths.sh`'s
`resolve_project_root` / `STUDIO_HOME` resolution; neither hand-rolls
`$HOME/.dev-studio` paths.

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
| pr-merge-finalize merge-target gate | (new in T-R004) | `STUDIO_BYPASS_BRANCH_POLICY=1` |

Assistants must not set the bypass on their own initiative; it is the user's
lever per the rule in CLAUDE.md §"Where workflow rules live".

## Implementation pointers

- `scripts/lib-feature-branch-policy.sh` — shared evaluator for the
  merge-commit invariant (#2 above).
- `scripts/pr-merge-finalize.sh` — applies invariants #2 and #3 against the
  GitHub PR before invoking `gh pr merge`.
- `.githooks/pre-commit` — applies invariant #1 (extended base-branch guard,
  reading the per-project release base from the policy file).
- `scripts/manager-feature-config.sh` (T-R001) — writes the policy settings
  consumed by the two surfaces above.

## Related

- `CLAUDE.md` §"Worktree protocol" — interactive sessions never edit the main
  checkout directly; the pre-commit guard is the safety net behind the
  worktree discipline.
- `REVIEW.md` — pulls in this standard for reviewer guidance.
