#!/usr/bin/env bash
# test-3156-ids.sh — fixture for #820 items 1 + 2.
#
# Exercises:
#   - _assert_uuidv7: valid UUIDv7 accepted, UUIDv4-marker rejected, bypass envvar honored
#   - _artifact_path: canonical UUID-named file used when present
#   - _artifact_path: legacy-named file (T<n>.yaml with matching id:) used as fallback
#   - _artifact_path: returns canonical when no match exists (writers create at canonical)

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t s3156-ids.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT=fixture-proj
PROJ_ROOT="$HOME/.dev-studio/fixture-proj"
mkdir -p "$PROJ_ROOT/plans/tasks"

pass=0
fail=0
assert() {
  local name="$1" expr="$2"
  if eval "$expr"; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    fail=$((fail + 1))
  fi
}

# Source lib-ledger so _assert_uuidv7 and _artifact_path are available.
# shellcheck disable=SC1090
. "$ROOT/scripts/lib-paths.sh"
# shellcheck disable=SC1090
. "$ROOT/scripts/lib-ledger.sh"

# ─── _assert_uuidv7 ───
VALID="0190f52a-9000-7f01-8aaa-77fe8fa99bbb"
INVALID4="c3680001-cf01-4a68-b368-000000000368"

_assert_uuidv7 "$VALID" 2>/dev/null; rc_valid=$?
assert "valid UUIDv7 accepted" '[ "$rc_valid" -eq 0 ]'

_assert_uuidv7 "$INVALID4" 2>/dev/null; rc_v4=$?
assert "UUIDv4-marker (4xxx) rejected" '[ "$rc_v4" -eq 2 ]'

_assert_uuidv7 "not-a-uuid" 2>/dev/null; rc_garbage=$?
assert "garbage id rejected" '[ "$rc_garbage" -eq 2 ]'

STUDIO_BYPASS_UUIDV7_CHECK=1 _assert_uuidv7 "$INVALID4" 2>"$TMPROOT/bypass.err"; rc_bypass=$?
assert "bypass envvar accepts non-UUIDv7 id" '[ "$rc_bypass" -eq 0 ]'
assert "bypass logs an audit line" \
  'grep -q "STUDIO_BYPASS_UUIDV7_CHECK" "$TMPROOT/bypass.err"'

# ─── _artifact_path canonical ───
canonical_uuid="0190f52a-9000-7f01-8aaa-000000aaaa01"
canonical_file="$PROJ_ROOT/plans/tasks/${canonical_uuid}.yaml"
printf 'id: %s\nstate: ready\n' "$canonical_uuid" > "$canonical_file"

resolved=$(_artifact_path tasks "$canonical_uuid")
assert "_artifact_path returns canonical path when file exists" \
  '[ "$resolved" = "$canonical_file" ]'

# ─── _artifact_path legacy fallback ───
synth_uuid="c3680001-cf01-4a68-b368-000000000368"
legacy_file="$PROJ_ROOT/plans/tasks/T368.yaml"
printf 'id: %s\nlegacy_task_id: T368\nstate: ready\n' "$synth_uuid" > "$legacy_file"

resolved=$(_artifact_path tasks "$synth_uuid")
assert "_artifact_path falls back to legacy filename via id: scan" \
  '[ "$resolved" = "$legacy_file" ]'

# ─── _artifact_path: no match → canonical (writer creates new file there) ───
new_uuid="0190f52a-9000-7f01-8aaa-deaddead1234"
expected_canonical="$PROJ_ROOT/plans/tasks/${new_uuid}.yaml"
resolved=$(_artifact_path tasks "$new_uuid")
assert "_artifact_path returns canonical for unknown uuid (writer path)" \
  '[ "$resolved" = "$expected_canonical" ]'

if [ "$fail" -gt 0 ]; then
  printf 'FAIL: %d test(s) failed\n' "$fail" >&2
  exit 1
fi
printf 'PASS: 3156-sweep id handling (%d/%d)\n' "$pass" "$pass"
