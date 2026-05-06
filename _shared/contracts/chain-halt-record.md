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
- finite retry policy metadata showing the auto-retry limit was exhausted or not applicable
- escalation metadata showing whether a human prompt is allowed for this halt class

True hard stops set `true_hard_stop: true`, `status: "terminated"`, and `next_command: null`. The runner must not execute a stored command automatically.

## Retry And Escalation Policy

The chain runner distinguishes routine continuation from useful human judgment:

- `attended` mode may prompt only for `review-needed`, `human-needed`, and `fatal` halt classes.
- `unattended` mode continues through routine plan, worker, ingest, outcome, PR, merge, and close boundaries until a typed blocker appears.
- Retryable infrastructure operations use a finite auto-retry budget from `STUDIO_CHAIN_RETRY_LIMIT` (default `2`) and `STUDIO_CHAIN_RETRY_BACKOFF_SEC` (default `2`). After the budget is exhausted, the runner writes a halt record instead of asking "should we continue?"
- Review gates are not retried as routine failures: blocked and ambiguous reviews stop as `review-needed`; reviewer host eligibility stops as `human-needed`.

## Reason Mapping

Writers choose only `reason_id`; the schema enforces the class.

| Halt class | Reason IDs |
|---|---|
| `retryable` | `github_auth_unavailable`, `github_home_mismatch`, `github_rate_limited`, `network_partition`, `child_timeout`, `disk_runtime_pressure` |
| `recoverable` | `parent_host_unknown`, `branch_worktree_conflict`, `base_branch_advanced`, `missing_child_summary`, `child_crash`, `issue_body_changed`, `partial_github_operation`, `test_build_infra_unavailable`, `telemetry_artifact_malformed`, `telemetry_artifact_missing`, `manifest_schema_version_mismatch`, `implementation_scope_blocked` |
| `review-needed` | `reviewer_blocked`, `reviewer_ambiguous` |
| `human-needed` | `reviewer_host_ineligible`, `model_tool_permission_prompt`, `context_output_overflow` |
| `fatal` | `required_review_failed`, `secret_detected`, `destructive_change_required`, `permission_expansion_required`, `unsafe_external_state` |

## Writer Responsibility

Parent runner writes infrastructure, review, git, GitHub, and runtime halts. Child workers surface model/tool prompts, context/output overflow, secrets, destructive changes, permission expansion, and scoped implementation hard stops through completion summaries; the parent may normalize those into halt records.

## Privacy

Halt records are private runtime artifacts under `~/.dev-studio/generic-dev-studio/chain-runs/<run_id>/halt-records/`. Public output may mention abstract reason IDs and the run ID, but not raw private prompts, local paths beyond the private report path, or sensitive details.
