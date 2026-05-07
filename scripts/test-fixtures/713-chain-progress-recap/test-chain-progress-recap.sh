#!/usr/bin/env bash
# Verifies chain-runner task completion recaps include progress and next command.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-progress-recap.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

extract="$TMPROOT/progress-recap.sh"
awk '/^print_issue_progress_recap\(\)/,/^process_completed_issue_result\(\)/ { if ($0 !~ /^process_completed_issue_result\(\)/) print }' \
  "$ROOT/scripts/studio-chain-runner.sh" > "$extract"

RUN_STATE_JSON="$TMPROOT/state.json"
SUMMARY="$TMPROOT/summary.json"
RUN_ID="run-progress-recap"
DRY_RUN=0
PLAN_JSON="$RUN_STATE_JSON"
export RUN_STATE_JSON SUMMARY RUN_ID DRY_RUN PLAN_JSON

cat > "$RUN_STATE_JSON" <<'JSON'
{
  "chains": [
    {
      "name": "context-hardening",
      "branch": "feature/context-hardening",
      "chain_run_id": "chain-1",
      "issues": [
        {"number": 711, "title": "Define Studio context contract", "issue_run_id": "issue-711", "status": "completed"},
        {"number": 712, "title": "Inventory path/auth resolution", "issue_run_id": "issue-712", "status": "completed"},
        {"number": 713, "title": "Add context resolver", "issue_run_id": "issue-713", "status": "pending"}
      ]
    }
  ]
}
JSON

cat > "$SUMMARY" <<'JSON'
{
  "functionality_delivered": "Documented the context boundary.",
  "tests": [{"command": "fixture", "outcome": "passed"}],
  "lints": [],
  "builds": []
}
JSON

# shellcheck disable=SC1090
. "$extract"

print_issue_progress_recap "context-hardening" "chain-1" "issue-712" "712" "$SUMMARY" > "$TMPROOT/out"

grep -q '## Chain Progress Recap' "$TMPROOT/out" || fail "missing recap heading"
grep -q 'Previous task: #711 Define Studio context contract (`completed`)' "$TMPROOT/out" || fail "missing previous task"
grep -q 'Just completed: #712 Inventory path/auth resolution (`completed`)' "$TMPROOT/out" || fail "missing completed task"
grep -q 'What changed: Documented the context boundary.' "$TMPROOT/out" || fail "missing change summary"
grep -q 'Next task: #713 Add context resolver (`pending`)' "$TMPROOT/out" || fail "missing next task"
grep -q 'Overall progress: 2/3 issues completed' "$TMPROOT/out" || fail "missing progress count"
grep -q 'Preferred command if this session stops: `/dev-studio manager work-chain --resume run-progress-recap --yes`' "$TMPROOT/out" \
  || fail "missing preferred dev-studio resume command"

printf 'PASS: chain progress recap\n'
