#!/usr/bin/env bash
# Verifies immediate child exits produce private startup diagnostics without env dumps.
# shellcheck disable=SC2034

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
TMPROOT=$(mktemp -d -t chain-startup-diagnostics-770.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
command -v yq >/dev/null 2>&1 || fail "yq required"

helpers="$TMPROOT/startup-helpers.sh"
# Keep these anchors in sync with the runner helper block; the fixture sources
# only the startup diagnostics helpers instead of the full runner.
awk '
  /^startup_diagnostics_artifact_path\(\)/ { capture=1 }
  /^codex_home_for_worker\(\)/ { capture=0 }
  capture { print }
' "$RUNNER" > "$helpers"

RUN_ID="019e0969-7700-7000-8000-000000000001"
CHAIN_RUN_ID="019e0969-7700-7000-8000-000000000002"
ISSUE_RUN_ID="019e0969-7700-7000-8000-000000000003"
STARTUP_DIAGNOSTICS_ROOT="$TMPROOT/startup-diagnostics"
REPO_ROOT="$ROOT"
export RUN_ID CHAIN_RUN_ID ISSUE_RUN_ID STARTUP_DIAGNOSTICS_ROOT REPO_ROOT

iso_ts_now() { printf '2026-05-09T00:00:00Z\n'; }
now_epoch() { printf '120\n'; }
duration_since() { printf '%s\n' "$(( ${2:-120} - $1 ))"; }

# shellcheck source=/dev/null
. "$helpers"

CAPS="$TMPROOT/capabilities.yaml"
cat > "$CAPS" <<'YAML'
supports_hooks: true
spawn_command: "scripts/codex-worker-exec.sh"
block_for_event_strategy: tail
tool_dialect: openai
sandbox_profile: workspace-write
secret_scope: cwd-only
YAML

resolve_capabilities_manifest() {
  printf '%s\n' "$CAPS"
}

WORKTREE="$TMPROOT/worktree"
mkdir -p "$WORKTREE/.studio"
SUMMARY_PATH="$WORKTREE/.studio/chain-worker-summary.json"
START_PATH="$WORKTREE/.studio/chain-task-start.json"
printf '{"schema_version":1}\n' > "$START_PATH"

export STUDIO_CHAIN_STARTUP_TAIL_BYTES=512
export GH_TOKEN="ghp_supersecret_fixture_token"

context_path=$(startup_launch_context_path "$ISSUE_RUN_ID")
write_child_launch_context \
  "$context_path" \
  "chain-startup-diagnostics" \
  "77001" \
  "codex" \
  "$WORKTREE" \
  "feature/chain-startup-diagnostics-issue-770" \
  "$SUMMARY_PATH" \
  "$START_PATH" \
  "" \
  "" \
  "scripts/codex-worker-exec.sh" \
  true

printf 'worker stdout before summary\nTOKEN=super-secret-stdout\n' > "$(startup_stdout_raw_path "$ISSUE_RUN_ID")"
cat > "$(startup_stderr_raw_path "$ISSUE_RUN_ID")" <<'ERR'
codex-worker-exec: Codex auth home not found; set CODEX_WORKER_HOME or CODEX_HOME to a directory containing Codex credentials
Authorization: Bearer super-secret-stderr
AKIA1234567890ABCDEF
ERR

update_child_launch_context_exit "$context_path" 70

session_telemetry='{"schema_version":1,"source":"codex_session_log","status":"missing","reason_id":"codex_home_mismatch","reason":"no usable Codex session directory was found for the worker launch HOME","fields":{}}'
artifact=$(write_child_startup_diagnostics \
  "chain-startup-diagnostics" \
  77001 \
  "codex" \
  "$WORKTREE" \
  "$SUMMARY_PATH" \
  70 \
  "$CHAIN_RUN_ID" \
  "$ISSUE_RUN_ID" \
  "worker_summary_missing" \
  "$session_telemetry")

jq -e --arg issue_run_id "$ISSUE_RUN_ID" '
  .schema_version == 1
  and .kind == "chain-child-startup-diagnostics"
  and .issue_run_id == $issue_run_id
  and .startup_failure_class == "cwd_auth_profile_mismatch"
  and .launch_stage == "child_exited"
  and .prompt_boundary.status == "not_detected"
  and .environment_shape.full_env_persisted == false
  and .environment_shape.secret_values_persisted == false
  and .streams.stdout.tail_artifact != null
  and .streams.stderr.tail_artifact != null
  and .streams.stdout.synchronization == "best_effort"
  and .streams.stderr.synchronization == "best_effort"
  and .streams.stderr.full_log_retained == false
' "$artifact" >/dev/null || {
  cat "$artifact" >&2
  fail "startup diagnostics artifact did not carry expected immediate-exit diagnostics"
}

[ ! -e "$(startup_stdout_raw_path "$ISSUE_RUN_ID")" ] || fail "stdout raw log was retained"
[ ! -e "$(startup_stderr_raw_path "$ISSUE_RUN_ID")" ] || fail "stderr raw log was retained"

if grep -R -E 'super-secret|ghp_supersecret|AKIA1234567890ABCDEF' "$STARTUP_DIAGNOSTICS_ROOT" >/dev/null 2>&1; then
  grep -R -n -E 'super-secret|ghp_supersecret|AKIA1234567890ABCDEF' "$STARTUP_DIAGNOSTICS_ROOT" >&2 || true
  fail "startup diagnostics persisted a secret-looking value"
fi

SUMMARY_ROOT="$TMPROOT/worker-summaries"
HALT_ROOT="$TMPROOT/halt-records"
ESCROW_ROOT="$TMPROOT/decision-escrows"
PHASE_REVIEW_ROOT="$TMPROOT/phase-reviews"
EVENTS_JSONL="$TMPROOT/events.jsonl"
RUN_STATE_JSON="$TMPROOT/state.json"
RUN_REPORT="$TMPROOT/report.md"
SCRIPT_DIR="$ROOT/scripts"
MANIFEST="chains/startup-diagnostics.yaml"
RUN_STARTED_AT=100
RUN_STARTED_TS="2026-05-09T00:00:00Z"
FINAL_PR_URL=""
mkdir -p "$SUMMARY_ROOT" "$HALT_ROOT" "$ESCROW_ROOT" "$PHASE_REVIEW_ROOT"
: > "$EVENTS_JSONL"

stdout_tail=$(jq -r '.streams.stdout.tail_artifact' "$artifact")
stderr_tail=$(jq -r '.streams.stderr.tail_artifact' "$artifact")
cat > "$SUMMARY_ROOT/issue-77001.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "$ISSUE_RUN_ID",
  "chain": "chain-startup-diagnostics",
  "issue_number": 77001,
  "host": "codex",
  "exit_code": 70,
  "duration_s": 20,
  "files_changed": 0,
  "additions": 0,
  "deletions": 0,
  "generated_file_count": 0,
  "summary_validation": "worker_summary_missing",
  "startup_diagnostics_artifact": "$artifact",
  "startup_failure_class": "cwd_auth_profile_mismatch",
  "startup_diagnostics": {
    "artifact": "$artifact",
    "failure_class": "cwd_auth_profile_mismatch",
    "launch_stage": "child_exited",
    "prompt_boundary_status": "not_detected",
    "stdout_tail_artifact": "$stdout_tail",
    "stderr_tail_artifact": "$stderr_tail"
  },
  "tokens": null,
  "tests": [],
  "lints": [],
  "builds": [],
  "telemetry_gaps": ["worker_summary_missing", "tokens", "model"]
}
JSON

halt_details=$(startup_halt_details_json "$SUMMARY_ROOT/issue-77001.json")
printf '%s\n' "$halt_details" | jq -e --arg artifact "$artifact" --arg stderr_tail "$stderr_tail" '
  .startup_diagnostics_artifact == $artifact
  and .startup_failure_class == "cwd_auth_profile_mismatch"
  and .stderr_tail_artifact == $stderr_tail
' >/dev/null || {
  printf '%s\n' "$halt_details" >&2
  fail "halt details did not point to startup diagnostics"
}

generate_helpers="$TMPROOT/generate-report.sh"
awk '/^generate_run_report\(\)/,/^finish_run\(\)/ { if ($0 !~ /^finish_run\(\)/) print }' \
  "$RUNNER" > "$generate_helpers"

# shellcheck source=/dev/null
. "$generate_helpers"
generate_run_report failed "fixture immediate child exit"

for needle in \
  "## Startup Diagnostics" \
  "cwd_auth_profile_mismatch" \
  "child_exited" \
  "not_detected" \
  "$artifact" \
  "$stderr_tail"
do
  grep -q "$needle" "$RUN_REPORT" || {
    printf 'missing report startup diagnostics needle: %s\n' "$needle" >&2
    cat "$RUN_REPORT" >&2
    fail "report did not surface startup diagnostics"
  }
done

printf 'PASS: chain child startup diagnostics\n'
