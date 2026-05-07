---
name: Studio Context Inventory
description: Abstract inventory of current path and auth resolution surfaces for the Studio context migration.
type: report
schema_version: 1
---

# Studio Context Inventory

This is the public, abstract companion to the private A2 inventory report for
#712. The detailed file-by-file hit list lives under
`~/.dev-studio/generic-dev-studio/analysis/` and must stay private because it
can include local runtime paths, host setup details, and cross-project context.

## Scanner

The inventory was produced from the repository root with deterministic `rg`
queries over tracked source-like files:

```bash
rg -n --hidden --glob '!.git/**' --glob '!node_modules/**' --glob '!vendor/**' --glob '!*.lock' \
  '\$HOME/\.dev-studio|~/\.dev-studio|\.codex-homes|\bgh\b|with_login_home_for_github|resolve_parent_home_for_github|studio_home_is_synthetic|NFSHomeDirectory|CLAUDE_REVIEWER_HOME|CODEX_HOME|HOME=|HOME\$|\$HOME' .

rg -n --glob 'scripts/*.sh' \
  '\$HOME/\.dev-studio|~/\.dev-studio|\.codex-homes|\bgh\b|with_login_home_for_github|resolve_parent_home_for_github|studio_home_is_synthetic|NFSHomeDirectory|CLAUDE_REVIEWER_HOME|CODEX_HOME|HOME=' .
```

The production-script scan found 79 `scripts/*.sh` files with at least one
path/auth/context hit. Most hits are documentation comments, approved
`lib-paths.sh` formulas, or existing wrapper use; the migration target is the
subset where operation intent is implicit in raw `HOME`, raw `gh`, or ad hoc
host auth selection.

## Classification Summary

| Class | Meaning | Examples |
|---|---|---|
| Approved resolver | Existing resolver and compatibility layers centralize the behavior. | `scripts/lib-studio-context.sh`, `scripts/lib-paths.sh`, `scripts/studio-gh.sh` |
| Migration target | Production code should move to the Studio context resolver once it exists. | Chain runner state roots, manager analyze/reconcile data-home rebinding, review wrapper auth-home selection |
| Bug | Current behavior is unsafe or already failed under the chain. | Child Codex worker launch can lose model auth when the launch home lacks usable Codex credentials |
| Doc example | Placeholder prose or examples; keep abstract or point at the contract. | README and contract examples using `~/.dev-studio/<project>` |
| Test fixture | Synthetic HOME/auth cases intentionally cover host behavior. | `scripts/test-fixtures/*parent-home*`, reviewer fixtures, host parity fixtures |
| Intentional temporary artifact | `$TMPDIR` and chain-runner worktrees are temporary by design but cannot be the only resume-critical references. | Chain issue worktrees and local scratch outputs |

## High-Risk Flows

| Flow | Classification | Migration note |
|---|---|---|
| Feedback ingest/analyze | Migration target | Resolve durable Studio feedback and analysis roots from `studio_home`; keep GitHub mutations behind `scripts/studio-gh.sh`. |
| Manager analyze/reconcile | Migration target | Replace ad hoc `HOME="$data_home"` rebinding with a context envelope carrying `studio_home`, `project_slug`, and visibility. |
| GitHub wrapper | Approved resolver owner | `scripts/studio-gh.sh` is the correct entry point; it consumes the context-backed `github_home` accessor while legacy call sites await migration. |
| PR review wrapper | Migration target | Reviewer auth homes are explicit today; move reviewer host profile selection into the context envelope and keep no-secret floors. |
| Phase review wrapper | Migration target | Same reviewer-profile migration as PR review, with degraded-review metadata preserved. |
| Chain runner state | Migration target plus bug | Durable run state belongs under `studio_home`; temporary worktree paths must not be the only resume-critical manifest references. Worker launch auth must use a host profile, not incidental `HOME`. |
| Chain monitor state | Migration target | Monitor and telemetry roots should consume the same project runtime root as the chain runner. |
| Project-profile lookup | Migration target | Profile operation resolution should receive `project_slug` and `repo_root` explicitly instead of relying on ambient repo/HOME context. |

## Ordered Migration List

1. Introduce `scripts/lib-studio-context.sh` with shell accessors for the
   envelope defined in `_shared/contracts/studio-context.md`.
2. Move `scripts/studio-gh.sh`, `host-preflight.sh`, and GitHub wrapper call
   sites to the context-backed `github_home` accessor.
3. Move `pr-headless-review.sh`, `phase-review.sh`,
   `pr-reviewer-eligibility.sh`, and `pre-commit-review.sh` to explicit
   `host_profile`, `auth_home`, and `github_home` selection.
4. Move `studio-chain-runner.sh`, chain monitor/reporting, and checkpoint
   resume paths to context-backed durable roots; record repo-relative manifest
   identity plus durable run state so `$TMPDIR` loss does not break resume.
5. Move manager analyze/reconcile and feedback ingest/reporting to
   context-backed `studio_home` and `project_slug` instead of rebinding `HOME`.
6. Move project-profile command resolution to consume explicit `repo_root` and
   `project_slug`.
7. Sweep remaining scripts, docs, and fixtures; retain synthetic-home fixtures
   as intentional test coverage and convert doc-only examples to contract
   pointers where they risk being copied into scripts.

## Public Summary for #710

The inventory confirms that Studio already has useful compatibility wrappers,
but context ownership is still spread across raw `HOME`, login-home
normalization, reviewer-home selection, and temporary chain paths. The next
implementation chain should build the resolver first, then migrate GitHub/auth
wrappers and chain-runner resume state before broader manager and profile
callers. Enforcement gates should wait until those migrations land.
