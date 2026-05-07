#!/usr/bin/env bash
# Verifies successful chain PR finalization repairs stale per-issue failure state.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-pr-finalize-state.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

helper_block=$(awk '
  /^update_state_jq\(\)/ { capture=1 }
  /^sanitize_checkpoint_component\(\)/ { capture=0 }
  capture { print }
' "$ROOT/scripts/studio-chain-runner.sh")

eval "$helper_block"

iso_ts_now() { printf '2026-05-07T00:00:00Z\n'; }

RUN_STATE_JSON="$TMPROOT/state.json"
after="defd4d78216a89f368eb7945e28a9fa08d7a04d5"

cat > "$RUN_STATE_JSON" <<JSON
{
  "schema_version": 1,
  "run_id": "run-700",
  "updated_at": "2026-05-07T00:00:00Z",
  "chains": [
    {
      "name": "release-approval-schema",
      "chain_run_id": "chain-700",
      "status": "completed",
      "pr_url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/pull/704",
      "issues": [
        {
          "number": 700,
          "issue_run_id": "issue-700",
          "status": "failed",
          "integrated": false,
          "commit_before": "5b411e425c036733026c78329bb3cf6eef176243",
          "commit_after": "5b411e425c036733026c78329bb3cf6eef176243",
          "failure_reason": "worker_exited_1"
        }
      ]
    }
  ]
}
JSON

mark_chain_issues_completed_after_pr "chain-700" "$after"

jq -e --arg after "$after" '
  .chains[0].issues[0].status == "completed"
  and .chains[0].issues[0].integrated == true
  and .chains[0].issues[0].commit_after == $after
  and (.chains[0].issues[0] | has("failure_reason") | not)
' "$RUN_STATE_JSON" >/dev/null || fail "finalized PR did not repair stale issue state"

printf 'PASS: chain PR finalization repairs issue state\n'
