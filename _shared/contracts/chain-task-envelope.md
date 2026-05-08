---
name: Chain Task Envelope
schema_version: 1
description: Compact private-runtime start and completion envelopes for autonomous studio chain task slices.
type: contract
---

# Chain Task Envelope

Autonomous studio chains use two lean envelopes so a fresh child session or a resuming parent can continue from bounded state instead of loading parent chat history, long transition plans, or private run reports.

| Kind | Path | Writer | Reader |
|---|---|---|---|
| `start` | `<issue-worktree>/.studio/chain-task-start.json` | `scripts/studio-chain-runner.sh` before spawning the child host | Worker, reviewer, or parent handoff consumer |
| `completion` | `<issue-worktree>/.studio/chain-worker-summary.json`, normalized into `~/.dev-studio/generic-dev-studio/chain-runs/<run_id>/worker-summaries/*.json` | Child host, then parent runner enrichment | Parent resume, report, and summary logic |

Formal validation lives in `_shared/contracts/chain-task-envelope.schema.json` and is available through:

```bash
scripts/validate-contract.sh chain-task-envelope <file>
```

## Start Envelope

Required fields:

| Field | Meaning |
|---|---|
| `schema_version` | Integer `1`. |
| `kind` | Literal `start`. |
| `created_at` | RFC3339 UTC time from the parent runner. |
| `run_id`, `chain_run_id`, `issue_run_id` | UUID join keys for invocation, chain, and issue slice. |
| `source_issue` | `{number,title,body,url,state}` from GitHub at launch time. |
| `ownership` | `{chain,branch,source_branch,issue_branch,worktree,host}`. `source_branch` is the selected task source and final PR base; older envelopes may omit it and imply `main`/`base`. |
| `execution_policy` | Mode, review gates, retry budget, and escalation rules the child should honor without reopening parent context. |
| `expected_summary_artifact` | Exact `.studio/chain-worker-summary.json` path the worker must write. |
| `required_checks` | String array seeded from runner-known requirements. |
| `allowed_assumptions` | String array of assumptions the child may rely on without reopening parent context. |
| `phase_review_context` | Optional compact private warnings, recommendations, and accepted plan adjustments forwarded from prior clean outcome reviews. |
| `stop_conditions` | String array describing when the child must stop and write a blocked completion envelope. |
| `privacy` | `{classification:"private-runtime",rules:[...]}`. |

New runner-written start envelopes also include optional `tool_preflight` with
non-blocking tool availability observed by the parent runner before child
launch. Older envelopes can omit it.

The start envelope is a private runtime artifact. It stays under `.studio` in the issue worktree and is removed by the chain runner during cleanup. `phase_review_context` is not human acceptance and must not include raw reviewer prose; it is only the compact subset needed to prevent stale assumptions in the next issue phase.

Issue worktrees live below the parent run UUID temporary root, not directly
under the shared `studio-chain-runner` temp directory. A resumed run keeps the
same `run_id`, `chain_run_id`, and `issue_run_id` values from `state.json`;
completed and integrated issues are skipped, completed but unintegrated issues
are integrated before new work starts, and pending dependency-ready issues are
relaunched with a fresh child session.

`execution_policy.mode` is `attended` or `unattended`. Attended mode allows questions only for real design, implementation, permission, destructive-change, test, or review judgment blockers. Unattended mode proceeds through routine boundaries until such a blocker appears. `execution_policy.retry` carries a finite auto-retry limit and backoff; exhausted retryable failures become typed halt records. `execution_policy.escalation.routine_continue_prompts` must remain `false`.

### ShellCheck Policy

`tool_preflight.tools.shellcheck.status` is `available` when the runner can see
ShellCheck on the worker launch path and `unavailable` otherwise. ShellCheck is
conditional evidence for touched shell or release scripts, not a universal
chain precondition.

When ShellCheck is unavailable, workers can still complete shell-script changes
only by recording the attempted ShellCheck lint as skipped with
`reason_id: shellcheck_expected_unavailable` and running accepted substitutes:
`bash -n` on touched shell scripts plus repo-specific lints or fixtures that
exercise the touched shell/release surface. That skipped lint is expected
unavailability. Omitting both ShellCheck and substitute evidence remains
verification drift.

## Completion Envelope

The completion envelope is additive over the existing #340/#446 worker summary surface. Child workers can keep writing `.studio/chain-worker-summary.json`; the parent runner injects missing `kind: "completion"` and `created_at` fields on ingest for both summary-present and summary-missing paths.

Required normalized fields:

| Field | Meaning |
|---|---|
| `schema_version` | Integer `1`. |
| `kind` | Literal `completion`. |
| `created_at` | RFC3339 UTC time when the parent normalized the summary. |
| `status` | Normalized completion status. |
| `run_id`, `chain_run_id`, `issue_run_id` | UUID join keys. |
| `host`, `exit_code`, `duration_s` | Execution metadata. |
| `commit_before`, `commit_after` | Git boundary for the issue slice. |
| `files_changed`, `additions`, `deletions`, `generated_file_count` | Diff stats computed by the parent when absent. |
| `changed_artifacts` | Changed file list when the parent can compute it. |
| `tests`, `lints`, `builds` | Arrays of command/outcome objects; empty means no evidence supplied. `lints[]` may include skipped expected tool unavailability with `reason_id` and `substitutes_run`. |
| `tokens` | Token telemetry object, number, or `null`. |
| `telemetry_gaps` | String array of missing telemetry fields. |

Optional normalized fields include `commit_or_pr_references`, `decisions_made`, `assumptions_escrowed`, `next_recommended_action`, `functionality_delivered`, `user_visible_change`, `refactoring_needed_now`, `refactoring_follow_ups`, `carryover`, `lessons`, and `blocked_reason`.

`refactoring_needed_now[]` lists cleanup that was required to complete the current bounded issue safely. `refactoring_follow_ups[]` lists deferred design debt with reason, affected area, risk, and suggested timing so parent summaries can distinguish "fixed as part of this task" from "proposed as follow-up work."

`decisions_made` and `assumptions_escrowed` may be strings, string arrays, compact objects, or arrays of compact objects. Full decision records validate against `_shared/contracts/chain-decision-escrow.schema.json` and remain private runtime artifacts; completion envelopes only need enough detail or references for phase outcomes and final digests to surface the decision.

When a child cannot complete safely, it should write `blocked_reason` and may include a closed `halt_reason_id` from `_shared/contracts/chain-halt-record.md`. Parent runners normalize infrastructure/review/git/GitHub/runtime failures into full halt records.

## Privacy

Active handoff artifacts contain only the bounded task brief, branch/worktree ownership, required checks, and machine-readable telemetry. Detailed private reports remain under `~/.dev-studio/generic-dev-studio/chain-runs/<run_id>/`; public outputs must keep the existing chain-run privacy rule and avoid raw sensitive prompts, secrets, project-private details, or `.studio` artifacts.

## Relationship To Existing Summaries

#340 remains the user-facing summary/reporting layer. This contract standardizes the machine-readable envelope that feeds those summaries; it does not redesign agent debriefs or replace the private chain run report.
