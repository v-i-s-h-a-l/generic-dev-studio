---
name: Chain Run Telemetry
schema_version: 1
description: Private append-only JSONL telemetry contract for autonomous studio chain runs.
type: contract
---

# Chain Run Telemetry

Autonomous studio chains write compact local telemetry to:

```text
~/.dev-studio/generic-dev-studio/chain-runs/<run_id>/events.jsonl
```

The file is private runtime state. It is append-only within one run directory; v1 uses atomic single-line JSONL appends and no external collector.

## Runtime Hygiene

Each non-dry-run invocation owns a run-scoped temporary root under:

```text
${TMPDIR:-/tmp}/studio-chain-runner/<run_id>/
```

Chain worktrees, issue worktrees, and per-issue result files stay under that
run UUID so concurrent chains cannot collide on path names. Completed runs
remove their temporary root after the private report is written. Failed or
halted runs keep their temporary root until a later hygiene sweep or manual
inspection.

At startup, the runner performs a bounded private sweep: stale state locks whose
PIDs are gone are removed, old temporary run roots are pruned, oversized old
private artifacts such as `events.jsonl`, `report.md`, and wrapper `.out` files
are gzip-archived when `gzip` is available, and old completed run directories
may be pruned. Defaults are intentionally conservative and can be tuned with
`STUDIO_CHAIN_TMP_RETENTION_DAYS`, `STUDIO_CHAIN_RUN_RETENTION_DAYS`, and
`STUDIO_CHAIN_ARTIFACT_MAX_BYTES`.

## Event Envelope

Every line carries the same top-level envelope:

| Field | Required | Meaning |
|---|---:|---|
| `schema_version` | yes | Integer `1`. |
| `run_id` | yes | Stable run UUID. A resumed run keeps the same value. |
| `created_at` | yes | RFC3339 UTC timestamp. |
| `event` | yes | Event name. |
| `stage` | yes | One of `plan`, `preflight`, `execute`, `ingest`, `review`, `merge`, `close`, `resume`, `finalize`. |
| `status` | yes | Compact status such as `running`, `completed`, `failed`, `missing`, `paused`, or `terminated`. |
| `attempt_id` | yes | UUID for this runner attempt. A resume gets a new `attempt_id`. |
| `chain_run_id`, `issue_run_id` | no | Join keys when the event belongs to a chain or issue slice. |
| `task` | no | Issue number, PR number, decision id, or empty string. |
| `data` | yes | Bounded object. Long/private details should be represented as private artifact paths. |

## Run Metrics

`state.json` stores a compact derived `efficiency_metrics` object. It is
computed from worker summaries plus events and is intentionally aggregate-only:
issue pass/fail counts, worker duration totals and averages, slowest issue,
token totals when available, churn totals, seconds/tokens per changed file,
retry/resume/review counters, test/lint/build outcome counts, telemetry-gap
counts, and a small `bottlenecks` array. Missing token or model telemetry stays
`null` or a named gap; readers must not coerce missing data to zero.

Per-issue objects also keep audit state that is more precise than the scheduler
`status`. `status` remains the compatibility field used for resume and
dependency scheduling (`pending`, `running`, `completed`, `failed`).
`lifecycle_state` and `lifecycle_history` distinguish the audit trail:
`issue-created`, `implementation-running`, `implemented-local`,
`smoke-passed`, `merged`, and `closed`. `provenance` records the mapped issue,
runner/session identifiers, local commit/summary references, merge point, and
closure PR when available.

## Required Event Data

| Event family | Required `data` fields |
|---|---|
| Supervisor: `chain_supervisor_decision` | Emitted for mutating `--auto` decisions; `--auto --dry-run` and `--explain-next` print the decision envelope without writing telemetry. Include `action`; include `selected_run_id` for resume/start when available, `candidate_run_ids` for ambiguity/refusals, `reason_id` for refusals, and `lock_path` for lock-held refusals. |
| Lifecycle: `chain_run_started`, `chain_started`, `chain_issue_started`, `chain_issue_completed`, `chain_issue_merged`, `chain_issue_closed`, `chain_completed`, `chain_run_completed` | `status`, `duration_s`; scoped IDs in the envelope; stage-specific fields such as `chain`, `host`, `commit_before`, `commit_after`, `pr_url`, or `report` when available. `chain_issue_completed` also carries compact `check_counts`, token presence, and telemetry gaps when a worker summary exists. |
| iOS execution summary on worker summaries | Optional `execution_telemetry` records implementation/build/test/review/release executors when applicable, routing reason class, cost/economics summary, private artifact roots, public-safe artifact classes, cleanup outcome, retained TTL class, failover outcome, and timing split across control-plane overhead, source sync, simulator boot, xcodebuild, tests, log parsing, and cleanup. Missing required iOS evidence is emitted as named telemetry gaps (`implementation_executor`, `build_executor`, `test_executor`, `review_executor`, `release_executor`, `worker_routing`, `artifact_evidence`, `cleanup_telemetry`) without failing an otherwise completed task. |
| iOS cleanup: `chain_ios_artifact_cleanup_completed` | `chain`, janitor `status`, redacted cleanup `counts`, `bytes_freed`, retained `retention_class`/TTL evidence when present, `paths_redacted`, and a private `telemetry_artifact` pointer. |
| Resume: `chain_resume_attempt_started`, `chain_resume_attempt_completed` | `attempt_id`; completed event also includes `failure_reason` when non-empty. |
| Halt: `chain_halt_recorded` | `reason_id`, `halt_class`, `halt_record`. |
| Escrow: `chain_decision_escrow_opened` | `decision_id`, `risk_class`, `status`, `escrow_record`. |
| Validation failure: `chain_artifact_validation_failed` | `artifact`, `reason_id`, `summary`. |
| Reviewer: `chain_review_completed` | `pr_url`, `exit_code`, `verdict` when wrapper output supplied it, `model`/`effort` when available, `wrapper_output`. |
| Gap: `chain_telemetry_gap` | `gap_kind`, `stage`, `reason`. Missing token/model/check data is a gap, never numeric zero. |
| HOME/auth normalization: `chain_auth_normalized` | `home_source`, `github_auth`, `secrets`. Do not emit actual HOME paths or secret material. |
| Automated checkpoints: `checkpoint_auto_created`, `checkpoint_auto_loaded`, `checkpoint_context_savings_estimated` | `checkpoint_id`, `role`, `branch`, compact size/token counters, drift status for loads, loaded file names, and private artifact pointers. Automated checkpoint events are private chain-run telemetry and do not replace worker summaries, phase reviews, PR reviews, halt records, decision escrows, event logs, or reports. |

## Public Surfaces

Public issue and PR comments may mention only this allowlist:

```text
issue_number, chain_name, stage, verdict, status, gap_kind, reason_id, run_id, PR/issue URLs
artifact_class, retention_class, cleanup_outcome, routing_reason_class, executor_role
```

Do not publish local paths, exact node or machine names, branch/work-project details, prompts, token totals, cache totals, velocity data, private task details, or raw reviewer output. Detailed reconstruction lives in the private report under the run directory.
