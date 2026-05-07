#!/usr/bin/env bash
# Verifies resume can reconcile a stale running issue from a completed worker summary.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-resume-summary-reconcile.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

helper_block=$(awk '
  /^git_checkout_exists\(\)/ { capture=1 }
  /^issue_dependencies_satisfied\(\)/ { capture=0 }
  capture { print }
' "$ROOT/scripts/studio-chain-runner.sh")

eval "$helper_block"

log() { printf 'log: %s\n' "$*" >> "$EVENTS"; }

phase_review_required_for_issue() {
  [ "$1" = "required" ]
}

write_issue_phase_outcome_artifact() {
  local artifact="$1"
  mkdir -p "$(dirname "$artifact")"
  printf 'outcome artifact\n' > "$artifact"
}

run_phase_review_gate() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$REVIEWS"
  return 0
}

emit_chain_event() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$4" "$5" "$6" "${8:-}" >> "$EVENTS"
}

mark_issue_state() {
  local issue_run_id="$1" status="$2" before="${3:-}" after="${4:-}" summary="${5:-}" reason="${6:-}"
  jq \
    --arg issue_run_id "$issue_run_id" \
    --arg status "$status" \
    --arg before "$before" \
    --arg after "$after" \
    --arg summary "$summary" \
    --arg reason "$reason" \
    '(.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .status) = $status
     | if $before == "" then . else (.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .commit_before) = $before end
     | if $after == "" then . else (.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .commit_after) = $after end
     | if $summary == "" then . else (.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .summary) = $summary end
     | if $reason == "" then . else (.chains[].issues[] | select(.issue_run_id == $issue_run_id) | .failure_reason) = $reason end' \
    "$RUN_STATE_JSON" > "$RUN_STATE_JSON.tmp"
  mv "$RUN_STATE_JSON.tmp" "$RUN_STATE_JSON"
}

RUN_ID="run-683"
# shellcheck disable=SC2034 # Consumed by functions extracted from studio-chain-runner.sh.
RESUME_ID="$RUN_ID"
# shellcheck disable=SC2034 # Consumed by functions extracted from studio-chain-runner.sh.
DRY_RUN=0
SUMMARY_ROOT="$TMPROOT/worker-summaries"
PHASE_REVIEW_ROOT="$TMPROOT/phase-reviews"
RUN_STATE_JSON="$TMPROOT/state.json"
PLAN_JSON="$TMPROOT/plan.json"
EVENTS="$TMPROOT/events.tsv"
REVIEWS="$TMPROOT/reviews.tsv"
# shellcheck disable=SC2034 # Set by the extracted scheduler recovery helpers on fatal review failures.
SCHEDULER_FAILURE_REASON=""
mkdir -p "$SUMMARY_ROOT" "$PHASE_REVIEW_ROOT"

ISSUE_WORKTREE="$TMPROOT/issue-worktree"
git init -q "$ISSUE_WORKTREE"
git -C "$ISSUE_WORKTREE" config user.name "Fixture"
git -C "$ISSUE_WORKTREE" config user.email "fixture@example.com"
printf 'base\n' > "$ISSUE_WORKTREE/file.txt"
git -C "$ISSUE_WORKTREE" add file.txt
git -C "$ISSUE_WORKTREE" commit -q -m "base"
before=$(git -C "$ISSUE_WORKTREE" rev-parse HEAD)
printf 'after\n' > "$ISSUE_WORKTREE/file.txt"
git -C "$ISSUE_WORKTREE" commit -aq -m "after"
after=$(git -C "$ISSUE_WORKTREE" rev-parse HEAD)

cat > "$PLAN_JSON" <<JSON
{
  "chains": [
    {
      "name": "resume-fixture",
      "chain_run_id": "chain-683",
      "issues": [
        {
          "number": 68301,
          "issue_run_id": "issue-683",
          "issue_worktree": "$ISSUE_WORKTREE"
        }
      ]
    }
  ]
}
JSON

cat > "$RUN_STATE_JSON" <<JSON
{
  "chains": [
    {
      "name": "resume-fixture",
      "chain_run_id": "chain-683",
      "issues": [
        {
          "number": 68301,
          "issue_run_id": "issue-683",
          "status": "running",
          "issue_worktree": "$ISSUE_WORKTREE"
        }
      ]
    }
  ],
  "phase_reviews": []
}
JSON

summary="$SUMMARY_ROOT/resume-fixture-issue-68301-issue-683.json"
cat > "$summary" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "status": "completed",
  "exit_code": 0,
  "run_id": "$RUN_ID",
  "chain_run_id": "chain-683",
  "issue_run_id": "issue-683",
  "issue_number": 68301,
  "commit_before": "$before",
  "commit_after": "$after",
  "duration_s": 3,
  "tests": [],
  "lints": [],
  "builds": []
}
JSON

reconcile_resume_issue_summaries 0 "resume-fixture" "chain-683" "required" 1 \
  || fail "reconciliation unexpectedly failed"

jq -e --arg summary "$summary" --arg after "$after" '
  .chains[0].issues[0].status == "completed"
  and .chains[0].issues[0].summary == $summary
  and .chains[0].issues[0].commit_after == $after
' "$RUN_STATE_JSON" >/dev/null || fail "state was not reconciled from summary"

grep -q '^outcome	chain-683-issue-683	' "$REVIEWS" \
  || fail "required outcome review was not run during reconciliation"

grep -q 'reconciled_from_summary' "$EVENTS" \
  || fail "completion event did not record summary reconciliation"

git -C "$ISSUE_WORKTREE" reset -q --hard "$before"
mark_issue_state "issue-683" running "" "" "" ""
: > "$EVENTS"
if reconcile_resume_issue_summaries 0 "resume-fixture" "chain-683" "required" 1; then
  :
else
  fail "unrecoverable summary should be skipped, not treated as fatal"
fi

jq -e '.chains[0].issues[0].status == "running"' "$RUN_STATE_JSON" >/dev/null \
  || fail "unreachable summary commit should not mark the issue completed"

printf 'PASS: chain resume summary reconciliation\n'
