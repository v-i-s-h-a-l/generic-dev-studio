#!/usr/bin/env bash
# test-suggestion-engine.sh — synthetic-fixture smoke test for #253.
#
# Runs in a HOME-overridden tmpdir against a unique throwaway slug so it never
# touches live project data (per studio rule: smoke-test new writers against
# synthetic fixtures, never live data — #273 wreck).
#
# Verifies:
#   1. emit a suggestion → events log records suggestion_emitted with the key
#   2. re-emit same key → exits with `skipped:dedupe`, no new event
#   3. resolve key → suggestion_resolved lands
#   4. re-emit after resolve → exits with `emitted` (key reopened)
#   5. query-suggestions.sh shows zero active when only resolved exists
#   6. query-suggestions.sh shows one active after the second emit

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

TMPDIR_OVERRIDE=$(mktemp -d -t suggestion-engine-XXXXXX)
trap 'rm -rf "$TMPDIR_OVERRIDE"' EXIT

SLUG="suggestion-test-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' ')"

export HOME="$TMPDIR_OVERRIDE"
export ACHILLES_PROJECT="$SLUG"
export STUDIO_HOST="claude-code"

EVENTS_DIR="$HOME/.dev-studio/$SLUG/events"
mkdir -p "$EVENTS_DIR"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf '  ok: %s\n' "$1"; }

KEY="chanakya:suggestion:stale_brief:test-uuid:7"

# 1. Initial emit
out=$("$SCRIPT_DIR/suggestion-emit.sh" \
  --kind stale_brief \
  --idem-key "$KEY" \
  --action-hint "test-uuid stale 9 days — re-brief or downgrade." \
  --payload '{"task_uuid":"test-uuid","state_age_days":9}' \
  --task "test-uuid" \
  --mode test) || fail "step 1: suggestion-emit failed (rc=$?)"
[ "$out" = "emitted" ] || fail "step 1: expected 'emitted', got '$out'"
pass "initial emit returned 'emitted'"

today=$(date -u +%Y-%m-%d)
log="$EVENTS_DIR/$today.jsonl"
[ -f "$log" ] || fail "step 1: event log not created at $log"
emit_count=$(jq -c "select(.event == \"suggestion_emitted\" and .idempotency_key == \"$KEY\")" "$log" | wc -l | tr -d ' ')
[ "$emit_count" -eq 1 ] || fail "step 1: expected 1 suggestion_emitted, found $emit_count"
pass "events log holds one suggestion_emitted"

# 2. Re-emit dedupe
out=$("$SCRIPT_DIR/suggestion-emit.sh" \
  --kind stale_brief \
  --idem-key "$KEY" \
  --action-hint "duplicate hint — should not fire." \
  --task "test-uuid" \
  --mode test) || fail "step 2: suggestion-emit failed (rc=$?)"
[ "$out" = "skipped:dedupe" ] || fail "step 2: expected 'skipped:dedupe', got '$out'"
emit_count=$(jq -c "select(.event == \"suggestion_emitted\" and .idempotency_key == \"$KEY\")" "$log" | wc -l | tr -d ' ')
[ "$emit_count" -eq 1 ] || fail "step 2: emit_count grew to $emit_count after dedupe"
pass "duplicate emit was deduped"

# 3. Resolve
"$SCRIPT_DIR/suggestion-resolve.sh" \
  --idem-key "$KEY" \
  --kind stale_brief \
  --reason user_acted \
  --task "test-uuid" \
  --mode test || fail "step 3: suggestion-resolve failed (rc=$?)"
resolve_count=$(jq -c "select(.event == \"suggestion_resolved\" and .idempotency_key == \"$KEY\")" "$log" | wc -l | tr -d ' ')
[ "$resolve_count" -eq 1 ] || fail "step 3: expected 1 suggestion_resolved, found $resolve_count"
pass "resolve emitted suggestion_resolved"

# 4. Re-emit after resolve — key is reopened
out=$("$SCRIPT_DIR/suggestion-emit.sh" \
  --kind stale_brief \
  --idem-key "$KEY" \
  --action-hint "test-uuid stale 16 days — re-brief or downgrade." \
  --task "test-uuid" \
  --mode test) || fail "step 4: suggestion-emit failed (rc=$?)"
[ "$out" = "emitted" ] || fail "step 4: expected 'emitted' after resolve, got '$out'"
pass "re-emit after resolve fired again"

# 5/6. query-suggestions.sh shape
KEY2="chanakya:suggestion:stale_brief:other:14"
"$SCRIPT_DIR/suggestion-emit.sh" \
  --kind stale_brief \
  --idem-key "$KEY2" \
  --action-hint "other-task stale 16 days." \
  --task "other-task" \
  --mode test >/dev/null || fail "seed: second key emit failed"

active_count=$("$SCRIPT_DIR/query-suggestions.sh" --format render | wc -l | tr -d ' ')
[ "$active_count" -eq 2 ] || fail "step 5: expected 2 active suggestions, got $active_count"
pass "query-suggestions reports both active keys"

"$SCRIPT_DIR/suggestion-resolve.sh" \
  --idem-key "$KEY" \
  --kind stale_brief \
  --reason user_acted \
  --task "test-uuid" \
  --mode test >/dev/null || fail "step 6: second resolve failed"
active_count=$("$SCRIPT_DIR/query-suggestions.sh" --format render | wc -l | tr -d ' ')
[ "$active_count" -eq 1 ] || fail "step 6: after resolve expected 1 active, got $active_count"
pass "query-suggestions drops the resolved key"

printf '\nPASS: suggestion engine smoke test\n'
