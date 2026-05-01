#!/usr/bin/env bash
# Smoke test for #218 priority build queue.

set -e
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../.." && pwd)

TMPHOME=$(mktemp -d -t studio-build-queue-fixture-XXXXXX)
trap 'rm -rf "$TMPHOME"' EXIT

export HOME="$TMPHOME"
mkdir -p "$HOME/.dev-studio/.runtime"
cat > "$HOME/.dev-studio/.runtime/nodes.json" <<'JSON'
{
  "nodes": [
    {"id": "fixture-laptop", "roles": ["xcodebuild", "release"], "enabled": true, "parallel_build_slots": 2},
    {"id": "fixture-bad", "roles": ["xcodebuild"], "enabled": true, "parallel_build_slots": "bad"}
  ]
}
JSON

# shellcheck source=../../../lib-paths.sh
. "$REPO/scripts/lib-paths.sh"
# shellcheck source=../../../lib-build-queue.sh
. "$REPO/scripts/lib-build-queue.sh"

EVENT_LOG="$TMPHOME/events.jsonl"
emit_event_keyed() {
  local agent="$1" kind="$2" event="$3" task="$4" data="$5"
  printf '{"agent":"%s","kind":"%s","event":"%s","task":"%s","data":%s}\n' \
    "$agent" "$kind" "$event" "$task" "$data" >> "$EVENT_LOG"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

echo "=== Test 1: node slot config defaults safely ==="
[ "$(bq_node_slots fixture-laptop)" = "2" ] || fail "fixture-laptop should have 2 slots"
[ "$(bq_node_slots fixture-bad)" = "1" ] || fail "malformed slot count should fall back to 1"
[ "$(bq_node_slots local)" = "1" ] || fail "synthetic local should stay single-slot"
echo "PASS: bq_node_slots"

echo
echo "=== Test 2: release entries sort ahead of older task/background entries ==="
Q="$HOME/.dev-studio/.runtime/build-queue/fixture-laptop"
bg=$(bq_enqueue "$Q" "BG-001" background xcodebuild none)
task=$(bq_enqueue "$Q" "T001" task xcodebuild none)
sleep 1
rel=$(bq_enqueue "$Q" "release-42" release xcodebuild asc,slack)

first=$(find "$Q" -maxdepth 1 -type f -name '*.json' | sort | head -1)
[ "$first" = "$rel" ] || fail "release entry should sort first"
[ "$(jq -r .secret_scope "$rel")" = "asc,slack" ] || fail "release entry missing secret_scope"
[ "$(jq -r .role "$rel")" = "xcodebuild" ] || fail "release entry missing role"
echo "PASS: release priority + entry schema"

echo
echo "=== Test 3: promotion telemetry fires for older lower-priority work ==="
bq_wait "$Q" "$rel" 1 1 "release-42" "fixture-laptop" || fail "release entry should be granted"
promo_count=$(jq -r 'select(.event=="build_queue_promoted") | .data.skipped_count' "$EVENT_LOG" | tail -1)
[ "$promo_count" = "2" ] || fail "expected skipped_count=2, got ${promo_count:-empty}"
granted_priority=$(jq -r 'select(.event=="build_queue_granted") | .data.priority' "$EVENT_LOG" | tail -1)
[ "$granted_priority" = "release" ] || fail "grant priority should be release"
echo "PASS: promoted + granted telemetry"

echo
echo "=== Test 4: slot window admits only the configured head entries ==="
bq_release "$rel"
bq_release "$bg"
bq_release "$task"
one=$(bq_enqueue "$Q" "T010" task xcodebuild none)
two=$(bq_enqueue "$Q" "T011" task xcodebuild none)
three=$(bq_enqueue "$Q" "T012" task xcodebuild none)
bq_wait "$Q" "$one" 2 0 "T010" "fixture-laptop" || fail "first of two slots should be eligible"
bq_wait "$Q" "$two" 2 0 "T011" "fixture-laptop" || fail "second of two slots should be eligible"
if bq_wait "$Q" "$three" 2 0 "T012" "fixture-laptop" 2>/dev/null; then
  fail "third entry should wait behind two occupied queue slots"
fi
echo "PASS: parallel slot window enforced"
