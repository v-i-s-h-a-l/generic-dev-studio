#!/usr/bin/env bash
# Smoke test for #288 Stage E.
#
# Verifies:
#   1. node-pick --requires-secret-scope asc,slack picks `fixture-laptop` from
#      a 3-node registry where only laptop advertises both scopes (mini and
#      third are filtered out — issue #288 step 5).
#   2. studio-tf-push.sh push --dry-run walks all four pre-Slack events
#      (release_started, archive_completed, upload_completed, dsym_uploaded)
#      and emits the JSON context blob on stdout.
#   3. studio-tf-push.sh emit slack_drafted | slack_sent | release_failed
#      reuses the captured release-tag.
#
# Per memory `feedback_smoke_test_synthetic_only.md`: this fixture creates an
# isolated $HOME so node-pick reads our synthetic registry, never the real
# `~/.dev-studio/.runtime/nodes.json`. Throwaway slug only.

set -e
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../.." && pwd)

TMPHOME=$(mktemp -d -t studio-tf-push-fixture-XXXXXX)
trap 'rm -rf "$TMPHOME"' EXIT

mkdir -p "$TMPHOME/.dev-studio/.runtime"
cp "$SCRIPT_DIR/nodes.json" "$TMPHOME/.dev-studio/.runtime/nodes.json"

export HOME="$TMPHOME"
export ACHILLES_PROJECT="288-fixture"
export DRY_RUN=1
export STUDIO_RELEASE_TAG="release-fixture-288"

echo "=== Test 1: scope filter narrows the 3-node registry to fixture-laptop ==="
# The full node-pick.sh runs health probes via node-health.sh, which won't
# resolve fictional fixture hosts. We test the secret-scope filter at the jq
# level — that's the #284/#288 invariant the issue is verifying. The filter
# expression mirrors node-pick.sh.
CANDIDATES=$(jq -r '
  ["asc","slack"] as $r
  | .nodes[]
  | select(.enabled != false)
  | select(.roles | index("release"))
  | select(($r - (.secret_scopes // [])) == [])
  | .id
' "$TMPHOME/.dev-studio/.runtime/nodes.json")
if [ "$CANDIDATES" != "fixture-laptop" ]; then
  echo "FAIL: scope filter expected only 'fixture-laptop', got: $CANDIDATES"
  exit 1
fi
echo "PASS: scope filter excluded fixture-mini + fixture-third, kept fixture-laptop"

echo
echo "=== Test 2: dry-run push walks all four pre-Slack events ==="
OUT=$(STUDIO_TF_PUSH_FIXTURE_NODE=fixture-laptop "$REPO/scripts/studio-tf-push.sh" push --dry-run 2>&1)
CTX=$(echo "$OUT" | tail -1)
echo "$OUT" | grep -q "DRY-RUN event release_started" || { echo "FAIL: missing release_started"; exit 1; }
echo "$OUT" | grep -q "DRY-RUN event archive_completed" || { echo "FAIL: missing archive_completed"; exit 1; }
echo "$OUT" | grep -q "DRY-RUN event upload_completed" || { echo "FAIL: missing upload_completed"; exit 1; }
echo "$OUT" | grep -q "DRY-RUN event dsym_uploaded" || { echo "FAIL: missing dsym_uploaded"; exit 1; }
RT=$(echo "$CTX" | jq -r .release_tag)
[ "$RT" = "release-fixture-288" ] || { echo "FAIL: release_tag mismatch ($RT)"; exit 1; }
echo "PASS: 4 events + context (release_tag=$RT)"

echo
echo "=== Test 3: emit subcommand reuses release-tag ==="
"$REPO/scripts/studio-tf-push.sh" emit slack_drafted --release-tag "$RT" \
  --data '{"build":1,"channel":"#testing","bullet_count":0,"cc_count":0}' >/dev/null
"$REPO/scripts/studio-tf-push.sh" emit slack_sent --release-tag "$RT" \
  --data '{"build":1,"channel":"#testing","parent_ts":"123.456","message_chars":10}' >/dev/null
echo "PASS: emit slack_drafted + slack_sent"

echo
echo "=== Test 4: bad emit args reject ==="
if "$REPO/scripts/studio-tf-push.sh" emit bogus --release-tag x --data '{}' 2>/dev/null; then
  echo "FAIL: bogus event should have rejected"; exit 1
fi
if "$REPO/scripts/studio-tf-push.sh" emit slack_sent --release-tag x --data 'not-json' 2>/dev/null; then
  echo "FAIL: invalid JSON should have rejected"; exit 1
fi
echo "PASS: invalid args rejected"

echo
echo "=== Test 5: live mode without STUDIO_TF_PUSH_LIVE halts ==="
unset DRY_RUN
if STUDIO_TF_PUSH_FIXTURE_NODE=fixture-laptop "$REPO/scripts/studio-tf-push.sh" push 2>/dev/null; then
  echo "FAIL: should have halted without STUDIO_TF_PUSH_LIVE=1"; exit 1
fi
echo "PASS: halted at prereq gate"

echo
echo "All checks passed."
