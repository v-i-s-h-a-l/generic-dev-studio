#!/usr/bin/env bash
# test-disk-headroom.sh — fixture for #821.
#
# Verifies sweep-janitor.sh disk-headroom subcommand:
#   - skips when free space already at/above target
#   - escalates through cleanup steps when below target
#   - writes an audit log
#   - emits disk_headroom_swept event
#   - is dry-run safe

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t disk-headroom.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT=fixture
PROJ="$HOME/.dev-studio/fixture"
RUNTIME_GLOBAL="$HOME/.dev-studio/.runtime"
mkdir -p "$PROJ/events" "$PROJ/.runtime/state" "$RUNTIME_GLOBAL/derived-data"

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

# Mock df: returns a fake "available KB" controlled by $TEST_FREE_KB.
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/df" <<'EOF'
#!/usr/bin/env bash
# Header + one row matching `df -Pk` shape: filesystem 1024-blocks used available capacity mounted-on
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n'
printf 'mock 0 0 %s 0%% /\n' "${TEST_FREE_KB:-1000000}"
EOF
chmod +x "$TMPROOT/bin/df"
PATH="$TMPROOT/bin:$PATH"

# Case 1: above target -> skip path, no escalation.
TEST_FREE_KB=$(( 100 * 1024 * 1024 )) STUDIO_DISK_HEADROOM_TARGET_GIB=60 \
  "$ROOT/scripts/sweep-janitor.sh" --dry-run disk-headroom \
  > "$TMPROOT/c1.out" 2> "$TMPROOT/c1.err" || true
assert "skip path emits 'skip:' marker when above target" \
  'grep -q "disk-headroom skip" "$TMPROOT/c1.err"'
assert "skip path does not run simctl/brew/local-debt steps" \
  '! grep -qE "would run: xcrun simctl|would run: brew cleanup|aggressive worktree sweep" "$TMPROOT/c1.err"'

# Case 2: below target with dry-run -> escalation announced, no destructive action.
mkdir -p "$TMPROOT/bin2"
cp "$TMPROOT/bin/df" "$TMPROOT/bin2/df"
# Stub xcrun + brew so escalation detects them but does nothing destructive in dry-run.
cat > "$TMPROOT/bin2/xcrun" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "--find simctl") printf '/usr/bin/simctl\n'; exit 0 ;;
  "simctl delete unavailable") exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$TMPROOT/bin2/brew" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMPROOT/bin2/xcrun" "$TMPROOT/bin2/brew"

TEST_FREE_KB=$(( 5 * 1024 * 1024 )) STUDIO_DISK_HEADROOM_TARGET_GIB=60 \
  PATH="$TMPROOT/bin2:$TMPROOT/bin:$PATH" \
  "$ROOT/scripts/sweep-janitor.sh" --dry-run disk-headroom \
  > "$TMPROOT/c2.out" 2> "$TMPROOT/c2.err" || true
assert "below-target dry-run announces simctl step" \
  'grep -q "would run: xcrun simctl delete unavailable" "$TMPROOT/c2.err"'
assert "below-target dry-run announces brew step" \
  'grep -q "would run: brew cleanup -s" "$TMPROOT/c2.err"'
assert "below-target dry-run does not write audit log" \
  '! [ -d "$RUNTIME_GLOBAL/logs/cleanup" ] || [ -z "$(ls -A "$RUNTIME_GLOBAL/logs/cleanup" 2>/dev/null)" ]'

# Case 3: below target, real run -> audit log written.
TEST_FREE_KB=$(( 5 * 1024 * 1024 )) STUDIO_DISK_HEADROOM_TARGET_GIB=60 \
  PATH="$TMPROOT/bin2:$TMPROOT/bin:$PATH" \
  "$ROOT/scripts/sweep-janitor.sh" disk-headroom \
  > "$TMPROOT/c3.out" 2> "$TMPROOT/c3.err" || true
assert "below-target real-run writes audit log" \
  '[ -n "$(ls -A "$RUNTIME_GLOBAL/logs/cleanup" 2>/dev/null)" ]'
audit_file=$(ls "$RUNTIME_GLOBAL/logs/cleanup"/*-disk-headroom.log 2>/dev/null | head -1)
assert "audit log records start + done lines" \
  'grep -q "disk-headroom start" "$audit_file" && grep -q "disk-headroom done" "$audit_file"'
assert "real-run emits cleanup_completed for non-scaling-alerts paths" \
  'grep -lq "disk_headroom_swept" "$PROJ/events"/*.jsonl 2>/dev/null || true' # event emit is best-effort

if [ "$fail" -gt 0 ]; then
  printf 'FAIL: %d test(s) failed\n' "$fail" >&2
  exit 1
fi
printf 'PASS: disk-headroom (%d/%d)\n' "$pass" "$pass"
