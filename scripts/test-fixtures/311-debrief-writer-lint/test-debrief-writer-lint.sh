#!/usr/bin/env bash
# test-debrief-writer-lint.sh — regression fixture for #311.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t debrief-writer-lint.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

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

make_repo() {
  local repo="$1"
  mkdir -p "$repo/scripts" "$repo/achilles/modes" "$repo/_shared/rules"
  cp "$ROOT/scripts/lint-debrief-writers.sh" "$repo/scripts/lint-debrief-writers.sh"
  chmod +x "$repo/scripts/lint-debrief-writers.sh"
  git -C "$repo" init >/dev/null 2>&1
}

GOOD="$TMPROOT/good"
make_repo "$GOOD"
cat > "$GOOD/scripts/task-emit-debrief.sh" <<'SH'
#!/usr/bin/env bash
write_debrief_artifact "$uuid" "$task" "$brief" task emitted
SH
cat > "$GOOD/achilles/modes/task.md" <<'MD'
---
name: task
description: fixture
type: mode-pack
schema_version: 1
---
Write YAML per _shared/contracts/debrief-format.md.
MD

BAD_SCRIPT="$TMPROOT/bad-script"
make_repo "$BAD_SCRIPT"
cat > "$BAD_SCRIPT/scripts/active-writer.sh" <<'SH'
#!/usr/bin/env bash
OUT="$HOME/.dev-studio/$PROJECT/plans/chanakya-inbox/$TASK-debrief.md"
printf '# debrief\n' > "$OUT"
SH

BAD_MODE="$TMPROOT/bad-mode"
make_repo "$BAD_MODE"
cat > "$BAD_MODE/achilles/modes/task.md" <<'MD'
---
name: task
description: fixture
type: mode-pack
schema_version: 1
---
Write the debrief markdown file to plans/chanakya-inbox/T001-debrief.md.
MD

bash "$GOOD/scripts/lint-debrief-writers.sh" >"$TMPROOT/good.out" 2>"$TMPROOT/good.err"
good_rc=$?
bash "$BAD_SCRIPT/scripts/lint-debrief-writers.sh" >"$TMPROOT/bad-script.out" 2>"$TMPROOT/bad-script.err"
bad_script_rc=$?
bash "$BAD_MODE/scripts/lint-debrief-writers.sh" >"$TMPROOT/bad-mode.out" 2>"$TMPROOT/bad-mode.err"
bad_mode_rc=$?

assert "canonical writer passes" "[ $good_rc -eq 0 ]"
assert "active markdown writer fails" "[ $bad_script_rc -ne 0 ]"
assert "script failure names E_DEBRIEF_LEGACY_WRITE" "grep -q 'E_DEBRIEF_LEGACY_WRITE' '$TMPROOT/bad-script.out'"
assert "mode prose legacy writer fails" "[ $bad_mode_rc -ne 0 ]"
assert "mode failure names E_DEBRIEF_LEGACY_WRITE" "grep -q 'E_DEBRIEF_LEGACY_WRITE' '$TMPROOT/bad-mode.out'"

printf '%s assertions, %s failures\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
