#!/usr/bin/env bash
# test-build-gate-postmortem.sh — fixture for #820 items 4 + 5.
#
# Exercises the helper functions in isolation:
#   - _preserve_failed_build_log moves build_log + build_json under
#     <runtime-global>/logs/build/<project>/<task>-<ts>-<status>.log.
#   - _under_min_wall_floor classifies short remote dispatches correctly.
#   - 7-day retention prune fires on each invocation.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TARGET="$ROOT/scripts/task-build-gate.sh"
TMPROOT=$(mktemp -d -t build-gate-pm.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT=fixture-proj
mkdir -p "$HOME/.dev-studio/.runtime"

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

# Source lib-paths so _preserve_failed_build_log can resolve runtime-global.
# shellcheck disable=SC1090
. "$ROOT/scripts/lib-paths.sh"

# Extract the two helpers from the script into the current shell so we can
# call them directly. The script as a whole has too many side effects to
# source whole.
eval "$(awk '
  /^_preserve_failed_build_log\(\) \{/,/^}$/ { print }
  /^_under_min_wall_floor\(\) \{/,/^}$/ { print }
' "$TARGET")"

# ─── Wall-time floor ───
TASK_ID="T999"
assert "default 60s floor: 30s under remote dispatch is below floor" \
  '_under_min_wall_floor 30'
assert "default 60s floor: 90s above floor" \
  '! _under_min_wall_floor 90'

STUDIO_BUILD_GATE_MIN_WALL_S=10
assert "explicit 10s floor: 5s below" '_under_min_wall_floor 5'
assert "explicit 10s floor: 20s above" '! _under_min_wall_floor 20'

STUDIO_BUILD_GATE_MIN_WALL_S=0
assert "floor=0 disables the check (60s no longer below)" \
  '! _under_min_wall_floor 60'

unset STUDIO_BUILD_GATE_MIN_WALL_S

# ─── Preserve failed build_log ───
build_log="$TMPROOT/build.log"
build_json="${build_log}.json"
printf 'xcodebuild output\nerror: thing happened\n' > "$build_log"
printf '{"errors":[{"message":"thing"}]}\n' > "$build_json"

_preserve_failed_build_log dispatch_failed >/dev/null 2>&1
preserve_dir="$(resolve_runtime_global)/logs/build/fixture-proj"
assert "preserved log directory exists" '[ -d "$preserve_dir" ]'
assert "preserved log file is present" \
  '[ -n "$(ls "$preserve_dir"/T999-*-dispatch_failed.log 2>/dev/null)" ]'
assert "preserved json sidecar is present" \
  '[ -n "$(ls "$preserve_dir"/T999-*-dispatch_failed.json 2>/dev/null)" ]'
assert "preserved log content matches" \
  'grep -q "thing happened" "$preserve_dir"/T999-*-dispatch_failed.log'
assert "original build_log path is gone (moved, not copied)" \
  '! [ -f "$build_log" ]'

# Empty build_log gets removed without a destination file.
build_log="$TMPROOT/empty.log"
build_json="${build_log}.json"
: > "$build_log"
: > "$build_json"
_preserve_failed_build_log build_invocation_failed >/dev/null 2>&1
assert "empty log removed, no destination file written for it" \
  '! [ -n "$(ls "$preserve_dir"/T999-*-build_invocation_failed.log 2>/dev/null)" ]'

# Retention prune: synthesize an old file (mtime 8 days ago) and confirm it
# disappears on next preserve invocation.
old_log="$preserve_dir/T999-19990101T000000Z-old.log"
printf 'old\n' > "$old_log"
touch -t 199901010000.00 "$old_log"
build_log="$TMPROOT/build2.log"
build_json="${build_log}.json"
printf 'newer xcodebuild output\n' > "$build_log"
_preserve_failed_build_log success_marker_absent >/dev/null 2>&1
assert "retention prune removes 8-day-old log" \
  '! [ -f "$old_log" ]'

if [ "$fail" -gt 0 ]; then
  printf 'FAIL: %d test(s) failed\n' "$fail" >&2
  exit 1
fi
printf 'PASS: build-gate postmortem (%d/%d)\n' "$pass" "$pass"
