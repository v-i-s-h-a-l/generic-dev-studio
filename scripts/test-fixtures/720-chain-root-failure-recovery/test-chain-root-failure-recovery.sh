#!/usr/bin/env bash
# Verifies failed root issues remain the actionable blocker for dependent chains.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-root-failure-recovery.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=../../../lib-chain-git.sh
. "$ROOT/scripts/lib-chain-git.sh"

retry_helpers=$(awk '
  /^summary_validation_reason\(\)/ { capture=1 }
  /^generate_run_report\(\)/ { capture=0 }
  capture { print }
' "$ROOT/scripts/studio-chain-runner.sh")

dependency_helpers=$(awk '
  /^pending_issue_count\(\)/ { capture=1 }
  /^issue_job_is_running\(\)/ { capture=0 }
  capture { print }
' "$ROOT/scripts/studio-chain-runner.sh")

eval "$retry_helpers"
eval "$dependency_helpers"

WORKTREE="$TMPROOT/worktree"
git init -q "$WORKTREE"
git -C "$WORKTREE" config user.name "Fixture"
git -C "$WORKTREE" config user.email "fixture@example.com"
printf 'base\n' > "$WORKTREE/file.txt"
git -C "$WORKTREE" add file.txt
git -C "$WORKTREE" commit -q -m "base"
before=$(git -C "$WORKTREE" rev-parse HEAD)

missing_summary="$TMPROOT/missing-summary.json"
cat > "$missing_summary" <<JSON
{
  "summary_validation": "worker_summary_missing",
  "telemetry_gaps": ["worker_summary_missing"],
  "worktree_state": "clean"
}
JSON

missing_summary_retry_eligible "$missing_summary" 1 "$before" "$before" "$WORKTREE" \
  || fail "missing summary with no commits and clean worktree should be retryable once"

printf 'dirty\n' > "$WORKTREE/dirty.txt"
if missing_summary_retry_eligible "$missing_summary" 1 "$before" "$before" "$WORKTREE"; then
  fail "dirty worktree should not be retried automatically"
fi

RUN_STATE_JSON="$TMPROOT/state.json"
cat > "$RUN_STATE_JSON" <<JSON
{
  "chains": [
    {
      "name": "root-failure",
      "issues": [
        {
          "number": 72001,
          "issue_run_id": "issue-root",
          "status": "failed",
          "failure_reason": "worker_exited_1",
          "exit_code": 1,
          "summary": "$missing_summary",
          "issue_worktree": "$WORKTREE"
        },
        {
          "number": 72002,
          "issue_run_id": "issue-dependent",
          "status": "pending",
          "dependencies": [72001]
        }
      ]
    }
  ]
}
JSON

blocker_json=$(failed_dependency_blocker_json 0)
printf '%s\n' "$blocker_json" | jq -e '
  .failed_issue == 72001
  and .failed_issue_run_id == "issue-root"
  and (.blocked_issues == [72002])
' >/dev/null || fail "failed dependency blocker did not identify root issue"

reason=$(failed_dependency_blocker_reason "$blocker_json")
case "$reason" in
  *'chain blocked by failed prerequisite #72001'*'blocked_by #72001 -> #72002'*'next_safe_action='*) ;;
  *) printf '%s\n' "$reason" >&2; fail "blocked dependency reason was not actionable" ;;
esac

awk '
  /missing_summary_retry_eligible "\$summary_file"/ { saw_retry=1 }
  /chain_git_prepare_issue_workspace.*"\$issue_worktree"/ && saw_retry { saw_fresh=1 }
  END { exit !(saw_retry && saw_fresh) }
' "$ROOT/scripts/studio-chain-runner.sh" \
  || fail "runner does not retry missing-summary clean failures in a fresh issue worktree"

printf 'PASS: chain root failure recovery\n'
