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
| `ownership` | `{chain,branch,issue_branch,worktree,host}`. |
| `expected_summary_artifact` | Exact `.studio/chain-worker-summary.json` path the worker must write. |
| `required_checks` | String array seeded from runner-known requirements. |
| `allowed_assumptions` | String array of assumptions the child may rely on without reopening parent context. |
| `stop_conditions` | String array describing when the child must stop and write a blocked completion envelope. |
| `privacy` | `{classification:"private-runtime",rules:[...]}`. |

The start envelope is a private runtime artifact. It stays under `.studio` in the issue worktree and is removed by the chain runner during cleanup.

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
| `tests`, `lints`, `builds` | Arrays of command/outcome objects; empty means no evidence supplied. |
| `tokens` | Token telemetry object, number, or `null`. |
| `telemetry_gaps` | String array of missing telemetry fields. |

Optional normalized fields include `commit_or_pr_references`, `decisions_made`, `assumptions_escrowed`, `next_recommended_action`, `functionality_delivered`, `carryover`, `lessons`, and `blocked_reason`.

## Privacy

Active handoff artifacts contain only the bounded task brief, branch/worktree ownership, required checks, and machine-readable telemetry. Detailed private reports remain under `~/.dev-studio/generic-dev-studio/chain-runs/<run_id>/`; public outputs must keep the existing chain-run privacy rule and avoid raw sensitive prompts, secrets, project-private details, or `.studio` artifacts.

## Relationship To Existing Summaries

#340 remains the user-facing summary/reporting layer. This contract standardizes the machine-readable envelope that feeds those summaries; it does not redesign agent debriefs or replace the private chain run report.
