#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/tf-slack-bridge-754.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

HOME="$TMPROOT/home"
PROJECT="tf-slack-fixture"
export HOME STUDIO_RELEASE_PROJECT="$PROJECT"
mkdir -p "$HOME/.dev-studio/$PROJECT/config"
cat >"$HOME/.dev-studio/$PROJECT/config/release.env" <<'ENV'
STUDIO_TF_SLACK_CHANNEL=C_TESTING
STUDIO_TF_SLACK_CHANNEL_NAME=#testing
ENV

context="$TMPROOT/context.json"
commits="$TMPROOT/commits.txt"
jq -nc '{release_tag:"release-4001-fixture",build:4001,version:"26.5.0",prev_build:4000,branch:"feature/tf-slack",tf_tag:"tf-26.5.0-4001"}' >"$context"
cat >"$commits" <<'EOF'
aaa111 | Add gallery import status
Change-Type: feature
Problem: Testers could not tell when gallery import finished.
Solution: The gallery now shows a completion state.
---
bbb222 | Fix collage save retry
Change-Type: bugfix-shipped
Problem: Collage save retry stopped after a temporary upload failure.
Solution: Retry state now survives the transient failure.
EOF

draft_json=$("$ROOT/scripts/studio-tf-slack.sh" draft --context "$context" --commits "$commits" --summary "Gallery import and collage saving are ready for testing.")
[ -r "$draft_json" ] || fail "draft metadata missing"

parent_path=$(jq -r '.parent_path' "$draft_json")
thread_path=$(jq -r '.thread_path' "$draft_json")
combined_path=$(jq -r '.combined_path' "$draft_json")

grep -q '^\[iOS\] build 4001 is available on TestFlight$' "$parent_path" || fail "parent headline missing"
grep -q '^Details in thread[.]$' "$parent_path" || fail "parent thread pointer missing"
grep -q '^\*New\*$' "$thread_path" || fail "thread missing New section"
grep -q 'Testers could not tell when gallery import finished' "$thread_path" || fail "composer output missing feature bullet"
"$ROOT/scripts/lint-build-release-message.sh" --file "$combined_path" --channel testflight

if "$ROOT/scripts/studio-tf-slack.sh" send --draft "$draft_json" --dry-run >"$TMPROOT/send-unapproved.out" 2>"$TMPROOT/send-unapproved.err"; then
  fail "send without approval unexpectedly passed"
fi
grep -q 'refusing to post without --approve' "$TMPROOT/send-unapproved.err" || fail "missing approval refusal"

"$ROOT/scripts/studio-tf-slack.sh" send --draft "$draft_json" --approve --dry-run >"$TMPROOT/send-approved.out"
jq -e '.approved == true and .sent.parent_ts == "dry-run-parent-ts"' "$draft_json" >/dev/null \
  || fail "approved dry-run send did not update draft metadata"

events_file="$HOME/.dev-studio/$PROJECT/events/$(date -u +%Y-%m-%d).jsonl"
[ -r "$events_file" ] || fail "release events were not emitted"
jq -e 'select(.event == "slack_drafted" and .task == "release-4001-fixture")' "$events_file" >/dev/null \
  || fail "missing slack_drafted event"
jq -e 'select(.event == "slack_sent" and .task == "release-4001-fixture")' "$events_file" >/dev/null \
  || fail "missing slack_sent event"

printf 'PASS: TestFlight Slack bridge\n'
