#!/usr/bin/env bash
# Verifies autonomous chain halt taxonomy and decision-escrow contracts.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-halt-escrow.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

RUN_ID="019dec7f-271e-7574-a4cc-ab2ec7edfd7c"
CHAIN_RUN_ID="019dec7f-2798-786f-a2b5-1bee59583334"
ISSUE_RUN_ID="019dec7f-2aec-7724-ac41-304d93f45f09"

cat > "$TMPROOT/retryable-halt-round-trip.json" <<JSON
{
  "schema_version": 1,
  "kind": "chain-halt-record",
  "created_at": "2026-05-03T00:00:00Z",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "$ISSUE_RUN_ID",
  "chain": "autonomous-continuation-loop-479",
  "issue_number": 479,
  "status": "paused",
  "reason_id": "github_rate_limited",
  "halt_class": "retryable",
  "writer": "parent-runner",
  "summary": "GitHub API rate limit prevented issue closure.",
  "resumable_state": {"run_state": "$TMPROOT/state.json"},
  "next_command": "scripts/studio-chain-runner.sh --resume $RUN_ID --yes",
  "affected_artifacts": ["state.json"],
  "rollback_path": "Wait for rate-limit reset, then resume.",
  "true_hard_stop": false,
  "human_action_required": false,
  "privacy": {"classification": "private-runtime"}
}
JSON

cat > "$TMPROOT/fatal-hard-stop.json" <<JSON
{
  "schema_version": 1,
  "kind": "chain-halt-record",
  "created_at": "2026-05-03T00:01:00Z",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "$ISSUE_RUN_ID",
  "status": "terminated",
  "reason_id": "secret_detected",
  "halt_class": "fatal",
  "writer": "child-worker",
  "summary": "A secret-like token appeared in the proposed diff.",
  "resumable_state": {"summary": "worker summary path"},
  "next_command": null,
  "affected_artifacts": ["worker-summary.json"],
  "rollback_path": "Remove the sensitive material and start a new reviewed plan.",
  "true_hard_stop": true,
  "human_action_required": true,
  "privacy": {"classification": "private-runtime"}
}
JSON

cat > "$TMPROOT/human-needed-halt.json" <<JSON
{
  "schema_version": 1,
  "kind": "chain-halt-record",
  "created_at": "2026-05-03T00:02:00Z",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "$ISSUE_RUN_ID",
  "status": "paused",
  "reason_id": "model_tool_permission_prompt",
  "halt_class": "human-needed",
  "writer": "child-worker",
  "summary": "The host requested permission for an operation the worker cannot approve unattended.",
  "resumable_state": {"summary": "worker summary path"},
  "next_command": "scripts/studio-chain-runner.sh --resume $RUN_ID --yes",
  "affected_artifacts": ["worker-summary.json"],
  "rollback_path": "Resolve the prompt or adjust the allowlist, then resume.",
  "true_hard_stop": false,
  "human_action_required": true,
  "privacy": {"classification": "private-runtime"}
}
JSON

cat > "$TMPROOT/low-risk-escrow-continued.json" <<JSON
{
  "schema_version": 1,
  "kind": "chain-decision-escrow",
  "created_at": "2026-05-03T00:03:00Z",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "$ISSUE_RUN_ID",
  "decision_id": "docs-only-default",
  "decision": "Treat a docs-only wording mismatch as safe to continue.",
  "default_chosen": "Continue and surface the assumption in the final digest.",
  "rationale": "The default does not change runtime behavior or bypass review/build gates.",
  "risk_class": "low-risk",
  "status": "continued",
  "affected_artifacts": ["_shared/contracts/chain-halt-record.md"],
  "rollback_path": "Edit the docs wording in a follow-up commit before release.",
  "review_deadline": "2026-05-10T00:03:00Z",
  "override_command": null,
  "privacy": {"classification": "private-runtime"}
}
JSON

"$ROOT/scripts/validate-contract.sh" chain-halt-record "$TMPROOT/retryable-halt-round-trip.json"
"$ROOT/scripts/validate-contract.sh" chain-halt-record "$TMPROOT/fatal-hard-stop.json"
"$ROOT/scripts/validate-contract.sh" chain-halt-record "$TMPROOT/human-needed-halt.json"
"$ROOT/scripts/validate-contract.sh" chain-decision-escrow "$TMPROOT/low-risk-escrow-continued.json"

cat > "$TMPROOT/bad-reason-class.json" <<JSON
{
  "schema_version": 1,
  "kind": "chain-halt-record",
  "created_at": "2026-05-03T00:04:00Z",
  "run_id": "$RUN_ID",
  "status": "paused",
  "reason_id": "secret_detected",
  "halt_class": "recoverable",
  "writer": "parent-runner",
  "summary": "Invalid class pairing must be rejected.",
  "resumable_state": {},
  "next_command": "scripts/studio-chain-runner.sh --resume $RUN_ID --yes",
  "affected_artifacts": [],
  "rollback_path": "N/A",
  "true_hard_stop": false
}
JSON

if "$ROOT/scripts/validate-contract.sh" chain-halt-record "$TMPROOT/bad-reason-class.json" >/dev/null 2>&1; then
  printf 'bad reason/class pairing unexpectedly passed\n' >&2
  exit 1
fi

SUMMARY_ROOT="$TMPROOT/summaries"
HALT_ROOT="$TMPROOT/halts"
EVENTS_JSONL="$TMPROOT/events.jsonl"
RUN_REPORT="$TMPROOT/report.md"
mkdir -p "$SUMMARY_ROOT" "$HALT_ROOT"
cp "$TMPROOT/human-needed-halt.json" "$HALT_ROOT/human-needed-halt.json"

cat > "$SUMMARY_ROOT/resume-after-halt-report-surfacing.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "chain": "autonomous-continuation-loop-479",
  "issue_number": 479,
  "host": "codex",
  "exit_code": 0,
  "duration_s": 1,
  "files_changed": 2,
  "additions": 10,
  "deletions": 0,
  "generated_file_count": 0,
  "tokens": null,
  "tests": [],
  "lints": [],
  "builds": [],
  "assumptions_escrowed": [
    {
      "decision": "Keep resume command manual.",
      "default_chosen": "Display the command but do not execute it.",
      "rationale": "Stored commands are operator instructions, not automation input.",
      "affected_artifacts": ["report.md"],
      "rollback_path": "Change the follow-up runner behavior before release.",
      "review_deadline": "2026-05-10T00:03:00Z"
    }
  ],
  "telemetry_gaps": ["tokens"]
}
JSON
: > "$EVENTS_JSONL"

awk '/^generate_run_report\(\)/,/^finish_run\(\)/ { if ($0 !~ /^finish_run\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$TMPROOT/generate-report.sh"

MANIFEST="chains/fixture.yaml"
RUN_STATUS="failed"
RUN_FAILURE_REASON="model permission prompt"
RUN_STARTED_AT=100
RUN_STARTED_TS="2026-05-03T00:00:00Z"
FINAL_PR_URL=""

iso_ts_now() { printf '2026-05-03T00:00:20Z\n'; }
now_epoch() { printf '120\n'; }
duration_since() { printf '%s\n' "$(( ${2:-120} - $1 ))"; }

# shellcheck source=/dev/null
. "$TMPROOT/generate-report.sh"
generate_run_report failed "model permission prompt"

grep -q '## Halt Records' "$RUN_REPORT" || {
  printf 'missing halt report section\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
}
grep -q 'model_tool_permission_prompt' "$RUN_REPORT" || {
  printf 'missing halt reason in report\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
}
grep -q '## Decision Escrow' "$RUN_REPORT" || {
  printf 'missing decision escrow report section\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
}
grep -q 'Keep resume command manual.' "$RUN_REPORT" || {
  printf 'missing escrow decision in report\n' >&2
  cat "$RUN_REPORT" >&2
  exit 1
}

printf 'PASS: chain halt taxonomy and decision escrow contracts\n'
