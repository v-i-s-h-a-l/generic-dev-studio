---
name: Chain Halt Record
schema_version: 1
description: Typed private-runtime halt records for autonomous studio chains.
type: contract
---

# Chain Halt Record

Autonomous studio chains write a `chain-halt-record` whenever execution pauses or terminates before normal completion. The halt record is separate from decision escrow: halts stop the run, while escrow records allow a low-risk default to continue.

Formal validation lives in `_shared/contracts/chain-halt-record.schema.json`:

```bash
scripts/validate-contract.sh chain-halt-record <file>
```

## Required Behavior

Every non-fatal halt must leave:

- a typed `reason_id`
- the validator-enforced `halt_class`
- a resumable state object
- one visible `next_command`, normally `scripts/studio-chain-runner.sh --resume <run_id> --yes`
- one `next_safe_action` describing what to inspect or correct before resuming
- compact `issue_context` when the halt can be tied to an issue, including issue-run id, issue number/title, status, dependencies, and commit-after when available
- finite retry policy metadata showing the auto-retry limit was exhausted or not applicable
- escalation metadata showing whether a human prompt is allowed for this halt class

True hard stops set `true_hard_stop: true`, `status: "terminated"`, and `next_command: null`. The runner must not execute a stored command automatically.

Retryable origin/network halts also carry optional coalescing metadata while
staying on `schema_version: 1`: `retry_count`, `first_seen`, `last_seen`,
`last_observed_command`, `last_observed_error`, `normalized_origin`,
`normalized_error`, `coalesce_key`, and `coalesced_observations`.
`retry_count` counts total equivalent observations, so the first write is `1`
and the first repeat is `2`.

## Retry And Escalation Policy

The chain runner distinguishes routine continuation from useful human judgment:

- `attended` mode may prompt only for `review-needed`, `human-needed`, and `fatal` halt classes.
- `unattended` mode continues through routine plan, worker, ingest, outcome, PR, merge, and close boundaries until a typed blocker appears.
- Retryable infrastructure operations use a finite auto-retry budget from `STUDIO_CHAIN_RETRY_LIMIT` (default `2`) and `STUDIO_CHAIN_RETRY_BACKOFF_SEC` (default `2`). After the budget is exhausted, the runner writes a halt record instead of asking "should we continue?"
- Repeated equivalent retryable origin/network halts update the first active
  halt record in place instead of appending more active halt records. The
  in-place file update must validate a temporary JSON file before `mv` replaces
  the durable record, and the run-state `halt_records[]` row is updated in
  place using the same coalesce key.
- Retryable halt cooldown guidance uses `STUDIO_CHAIN_RETRY_HALT_COOLDOWN_SEC`
  (default `30`). `0` disables cooling-down guidance. Resume/report wording is
  `cooling_down` until `cooldown_until`, `retrying` after cooldown elapses, and
  `needs_human_inspection` once `retry_count` reaches
  `STUDIO_CHAIN_RETRY_HALT_INSPECTION_COUNT` (default `3`).
- Review gates are not retried as routine failures: blocked and ambiguous reviews stop as `review-needed`; reviewer host eligibility stops as `human-needed`.

## Retryable Coalescing Key

Writers coalesce only `halt_class: retryable` records that already have a
`coalesce_key`. Legacy active halt records without a key are left untouched.
Non-retryable records remain append-only until normal completion supersedes
them.

When multiple active halts exist, resume/report surfaces select the most severe
record in this order: `fatal`, `human-needed`, `review-needed`, `recoverable`,
`retryable`, then unknown classes. Ties use `created_at` and then the run-state
row order, so the latest equal-severity row wins.

The coalesce key is:

- `run_id`
- scope id: `issue_run_id` when present, otherwise `chain_run_id`, otherwise the run id
- scope kind: `issue_run`, `chain_run`, or `run`
- `reason_id`
- normalized origin
- normalized error

Origin normalization lowercases values, strips GitHub schemes and `.git`
suffixes, collapses `git@github.com:owner/repo.git`,
`https://github.com/owner/repo.git`, `https://github.com/owner/repo`, and
`owner/repo`-style GitHub command origins to `github.com/owner/repo`, and
collapses local temp/private paths to `local-path`. Missing origin is
`unknown`.

Error normalization lowercases text, collapses whitespace, removes command
quoting differences, and replaces UUIDs, ISO timestamps, hex SHAs, and temp
paths with placeholders. Missing error is `unknown`.

`coalesced_observations` is capped at five entries: the first observation plus
the four latest observations. This preserves first/last/sample evidence without
allowing a long-lived flapping network halt to grow unbounded.

## Reason Mapping

Writers choose only `reason_id`; the schema enforces the class.

| Halt class | Reason IDs |
|---|---|
| `retryable` | `github_auth_unavailable`, `github_home_mismatch`, `github_rate_limited`, `network_partition`, `child_timeout`, `disk_runtime_pressure` |
| `recoverable` | `parent_host_unknown`, `branch_worktree_conflict`, `base_branch_advanced`, `missing_child_summary`, `child_crash`, `issue_body_changed`, `partial_github_operation`, `test_build_infra_unavailable`, `telemetry_artifact_malformed`, `telemetry_artifact_missing`, `manifest_schema_version_mismatch`, `implementation_scope_blocked`, `checkpoint_drift_detected` |
| `review-needed` | `reviewer_blocked`, `reviewer_ambiguous` |
| `human-needed` | `reviewer_host_ineligible`, `model_tool_permission_prompt`, `context_output_overflow` |
| `fatal` | `required_review_failed`, `secret_detected`, `destructive_change_required`, `permission_expansion_required`, `unsafe_external_state` |

## Writer Responsibility

Parent runner writes infrastructure, review, git, GitHub, and runtime halts. Child workers surface model/tool prompts, context/output overflow, secrets, destructive changes, permission expansion, and scoped implementation hard stops through completion summaries; the parent may normalize those into halt records.

Checkpoint drift halts attach a private `details` object with the checkpoint id,
expected commit, observed commit, drift artifact path, and read-set artifact
path when resume tracing produced one. The drift artifact stores the same
commit pair plus the read-set list so recovery does not require parsing chat
history or rerunning checkpoint resume just to see what changed.

## Privacy

Halt records are private runtime artifacts under `~/.dev-studio/generic-dev-studio/chain-runs/<run_id>/halt-records/`. Public output may mention abstract reason IDs and the run ID, but not raw private prompts, local paths beyond the private report path, or sensitive details.
