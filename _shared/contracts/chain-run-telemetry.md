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

## Required Event Data

| Event family | Required `data` fields |
|---|---|
| Lifecycle: `chain_run_started`, `chain_started`, `chain_issue_started`, `chain_issue_completed`, `chain_completed`, `chain_run_completed` | `status`, `duration_s`; scoped IDs in the envelope; stage-specific fields such as `chain`, `host`, `commit_before`, `commit_after`, or `report` when available. |
| Resume: `chain_resume_attempt_started`, `chain_resume_attempt_completed` | `attempt_id`; completed event also includes `failure_reason` when non-empty. |
| Halt: `chain_halt_recorded` | `reason_id`, `halt_class`, `halt_record`. |
| Escrow: `chain_decision_escrow_opened` | `decision_id`, `risk_class`, `status`, `escrow_record`. |
| Validation failure: `chain_artifact_validation_failed` | `artifact`, `reason_id`, `summary`. |
| Reviewer: `chain_review_completed` | `pr_url`, `exit_code`, `verdict` when wrapper output supplied it, `model`/`effort` when available, `wrapper_output`. |
| Gap: `chain_telemetry_gap` | `gap_kind`, `stage`, `reason`. Missing token/model/check data is a gap, never numeric zero. |
| HOME/auth normalization: `chain_auth_normalized` | `home_source`, `github_auth`, `secrets`. Do not emit actual HOME paths or secret material. |

## Public Surfaces

Public issue and PR comments may mention only this allowlist:

```text
issue_number, chain_name, stage, verdict, status, gap_kind, reason_id, run_id, PR/issue URLs
```

Do not publish local paths, branch/work-project details, prompts, token totals, cache totals, velocity data, private task details, or raw reviewer output. Detailed reconstruction lives in the private report under the run directory.
