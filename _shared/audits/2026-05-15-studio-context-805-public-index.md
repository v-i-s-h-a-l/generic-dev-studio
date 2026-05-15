---
name: 2026-05-15-studio-context-805-public-index
description: Public-safe index for issue #805 studio context RCA artifacts and follow-up buckets. Detailed inventory payloads remain private-runtime.
type: audit
---

# Studio Context #805 Public Index

This public index records sanitized proof that the private-runtime RCA and
inventory for issue #805 were produced for issue #912. It intentionally omits
private runtime payloads, local machine paths, detailed file:line scan results,
and telemetry bodies.

## Private Artifacts

| Artifact | Visibility | Public status |
|---|---|---|
| `resolved-generic-dev-studio-analysis-runtime/studio-context-rca-805.md` | private-runtime | Produced; not committed |
| `resolved-generic-dev-studio-analysis-runtime/studio-context-inventory-805.json` | private-runtime | Produced; not committed |

## RCA Section Checklist

| Required section | Status |
|---|---|
| Summary | present |
| Root cause | present |
| Contributing factors | present |
| Impact | present |
| Inventory schema | present |
| Search scope | present |
| Aggregate findings | present |
| Verification fixtures | present |
| Public hygiene constraints | present |
| Stop-condition evaluation | present |

## Inventory Schema Checklist

| Field | Status |
|---|---|
| `schema_version` | present |
| `generated_for` | present |
| `visibility` | present |
| `search_scope` | present |
| `classification_rules` | present |
| `aggregate_counts` | present |
| `production_hotspots` | present with repo-relative paths only |
| `verification` | present |
| `public_hygiene` | present |
| `stop_conditions` | present |

## Search Scope Summary

The inventory scan used `rg` over repository source-like content, excluding Git
metadata, private runtime artifacts, dependency/vendor folders, and lockfiles.
The pattern family covered raw durable runtime paths, synthetic-home markers,
GitHub/auth wrapper usage, host auth variables, Studio context envelope
variables, resolver helper names, and raw `HOME` command environment usage.

## Aggregate Counts

| Operation class | Risk | Match count | File count |
|---|---:|---:|---:|
| approved_resolver | low | 211 | 3 |
| docs_contract | low | 370 | 87 |
| fixture_only | low | 908 | 135 |
| other | medium | 161 | 27 |
| production | high | 220 | 80 |
| production | medium | 487 | 81 |

## Verification Evidence

| Command | Outcome |
|---|---|
| `rg` inventory aggregation command | passed; produced operation_class/risk counts above |
| `env -u CODEX_REVIEWER_HOME -u CLAUDE_REVIEWER_HOME -u CODEX_HOME -u CODEX_WORKER_HOME scripts/test-fixtures/732-studio-context/test-studio-context.sh` | passed; clean auth-home environment used so the fixture exercises default reviewer-home resolution |
| `tests/lib-host-eligibility/test-lib-host-eligibility.sh` | passed |
| Public hygiene scan for absolute paths, token-like secrets, private chain artifact names, and private artifact body leakage | passed |

## Public Hygiene Result

The intended public surface is limited to artifact names, checklist status,
aggregate counts, verification outcomes, and public-safe follow-up placeholders.
Private RCA text, private inventory bodies, detailed file:line results, tokens,
credential material, host-auth payloads, and machine-specific absolute paths
must remain out of this committed file and out of issue comments.

## High-Risk Production Follow-Up Map

The regenerated high-risk production inventory is mapped at file granularity
below. Row identifiers are repo-relative file names only; detailed match
payloads remain private-runtime.

| Row identifiers | Follow-up assignment | Recurrence explanation |
|---|---|---|
| `scripts/studio-chain-runner.sh`, `scripts/studio-chain-doctor.sh`, `scripts/studio-chain-reviewed.sh`, `scripts/studio-chain-rule-gates.sh`, `scripts/studio-chain-telemetry-digest.sh`, `scripts/studio-checkpoint.sh`, `scripts/studio-dependency-export.sh` | Proposed issue: `context-migration/chain-runner-state` | Prior fixes handled individual symptoms, but chain state, resume, worktree, and report code still cross temporary roots, durable runtime roots, and host launch context in one layer. |
| `scripts/host-preflight.sh`, `scripts/lib-github-transport.sh`, `scripts/pr-autopilot.sh`, `scripts/pr-headless-review.sh`, `scripts/pr-merge-finalize.sh`, `scripts/pr-reviewer-eligibility.sh`, `scripts/dispatch-review.sh`, `scripts/lib-review-host.sh`, `scripts/studio-gh-issue-new.sh` | Proposed issue: `context-migration/github-review-auth` | Wrapper fixes reduced raw `gh` drift, but review and PR paths still need consistent `github_home`, reviewer `auth_home`, and no-secret launch envelopes across parent hosts. |
| `scripts/lint-gh-wrapper.sh`, `scripts/lint-gh-wrapper-allowlist.txt`, `scripts/lint-runtime-paths.sh`, `scripts/lint-runtime-paths-allowlist.txt`, `scripts/lint-synthetic-home.sh`, `scripts/lint-synthetic-home-allowlist.txt`, `scripts/lint-host-agnostic.sh`, `scripts/v2-router-lint.sh` | Proposed issue: `context-migration/enforcement-surfaces` | Enforcement scripts intentionally scan risky patterns, but their allowlist and diagnostic paths need a shared context vocabulary so new guards do not encode another ad hoc home model. |
| `scripts/manager-analyze.sh`, `scripts/manager-reconcile.sh`, `scripts/manager-plan-chain.sh`, `scripts/manager-chain-monitor.sh`, `scripts/manager-feature-config.sh`, `scripts/manager-release-branch.sh`, `scripts/chain-monitor-sync.sh`, `scripts/studio-project-add.sh`, `scripts/studio-project-state.sh`, `scripts/studio-staleness-triage.sh`, `scripts/studio-weekly.sh`, `scripts/studio-audit.sh`, `scripts/studio-guard.sh`, `scripts/budget-report.sh`, `scripts/graduation-scan.sh` | Proposed issue: `context-migration/manager-project-runtime` | Manager and project surfaces span repo roots, project runtime roots, and GitHub/project-board calls; recurrence happened because callers normalized one path class without carrying the full context envelope. |
| `scripts/analyze-collect.sh`, `scripts/analyze-feedback-ingest.sh`, `scripts/ingest-feedback.sh`, `scripts/slack-fetch.sh`, `scripts/slack-post.sh`, `scripts/argus-axe-verify.sh`, `scripts/argus-emit-verdict.sh`, `scripts/argus-setup.sh`, `scripts/emit-agent-boot.sh`, `scripts/emit-event.sh`, `scripts/read-shared.sh`, `scripts/write-shared.sh` | Proposed issue: `context-migration/feedback-events-shared-io` | Feedback, event, and shared-IO paths still mix durable project state with process-local assumptions; symptom fixes recurred when callers moved between hosts with different `HOME` semantics. |
| `scripts/bootstrap.sh`, `scripts/configure.sh`, `scripts/install-recipe.sh`, `scripts/install-skill-launchagent.sh`, `scripts/install-disk-headroom-launchagent.sh`, `scripts/install-node-janitor-launchagent.sh`, `scripts/rollback-recipe.sh`, `scripts/schedule-chain-monitor.sh`, `scripts/schedule-worker-sync.sh`, `scripts/fleet-cleanup.sh`, `scripts/node-janitor.sh`, `scripts/sweep-janitor.sh`, `scripts/sweep-process-events.sh` | Proposed issue: `context-migration/install-scheduled-cleanup` | Install and scheduled cleanup code legitimately touches login-home and machine-global state, but still needs explicit owner/visibility fields to avoid treating cleanup roots as host auth or project runtime roots. |
| `scripts/node-dispatch.sh`, `scripts/node-health.sh`, `scripts/node-monitor.sh`, `scripts/node-parity.sh`, `scripts/node-pick.sh`, `scripts/snapshot-sync.sh`, `scripts/sync-shared-remote.sh`, `scripts/sync-worker.sh`, `scripts/task-build-gate.sh`, `scripts/task-test-gate.sh`, `scripts/task-worktree-setup.sh`, `scripts/achilles-worker.sh`, `scripts/codex-worker-exec.sh`, `scripts/worker-status.sh`, `scripts/test-host.sh` | Proposed issue: `context-migration/worker-node-transport` | Worker and node flows copy context across machines and subprocesses; recurrence is likely until launch home, auth home, GitHub home, and runtime roots are explicit in the handoff. |
| `scripts/appstore-watch.sh`, `scripts/studio-tf-push.sh`, `scripts/lib-release-config.sh` | Proposed issue: `context-migration/release-secrets-runtime` | Release flows must distinguish release secrets, GitHub credentials, project runtime state, and local checkouts; prior fixes addressed push/auth symptoms without a full release-action context envelope. |
| `scripts/lib-build-queue.sh`, `scripts/lib-chain-monitor-config.sh`, `scripts/lib-dispatch-harvest.sh`, `scripts/lib-dispatch-registry.sh`, `scripts/lib-host-eligibility.sh`, `scripts/lib-project-board.sh`, `scripts/lib-source-sync.sh`, `scripts/lib-stepwise.sh`, `scripts/machine-id.sh`, `scripts/jsonl-merge.sh`, `scripts/issue-body-edit.sh`, `scripts/migrate-ledger.sh`, `scripts/scaffold-agent.sh`, `scripts/track-next.sh`, `scripts/update-recipes.sh`, `scripts/waive-lift.sh`, `scripts/waive-start.sh` | Proposed issue: `context-migration/shared-helper-sweep` | Shared helpers are reused by multiple surfaces; recurrence happens when each caller patches its own home/path behavior instead of consuming the resolver contract through one helper boundary. |
| `hooks/session-start`, `scripts/README.md`, `scripts/chanakya-snap.sh`, `scripts/chanakya-snap-prewarm.sh`, `scripts/studio-codex-reviewer-bootstrap.sh`, `scripts/studio-pr-baseline-report.sh`, `scripts/test-suggestion-engine.sh` | Proposed issue: `context-migration/bootstrap-doc-compat` | Compatibility and doc-adjacent scripts preserve older host assumptions; they should either move to the resolver or be marked as intentional examples/fixtures so future migrations do not chase false positives. |

## Public-Safe Follow-Ups

- Create the proposed migration issues above, or merge compatible buckets into
  existing context-migration issues before implementation starts.
- Keep fixture-only matches as regression coverage unless a fixture duplicates
  obsolete behavior without an assertion.
- Keep future public summaries aggregate-only; store detailed scan payloads in
  private runtime artifacts.
