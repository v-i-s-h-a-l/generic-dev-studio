#!/usr/bin/env bash
# duration-s-guardrails.sh — regression test for duration_s garbage emissions.
#
# Regression guarded:
#   Issue #107 / agent_session_completed.duration_s carried three bad shapes:
#     - `1776950221` (~56 years) when the start stamp file contained 0 and
#       the computation did `NOW - 0`.
#     - `null` (or field omitted entirely) on session paths that bypassed
#       the helper.
#     - Prose strings (`"~1800"`, `"~2400"`) on paths where the model wrote
#       duration_s by hand.
#
#   The fix (closes #107): emit-side plausibility guards with OMIT-on-fail
#   semantics. When the computed value fails a guard, the field is dropped
#   from the event entirely rather than fabricated. Readers treat "field
#   absent" as "session recorded but timing unreliable" instead of trusting
#   a plausible-looking lie.
#
# Assertions:
#   1. Integer form, plausible value (e.g. 60) → duration_s:60 in payload.
#   2. Integer form exceeding the 86400s cap → duration_s OMITTED.
#   3. `auto:<sid>` with no stamp file → duration_s OMITTED.
#   4. `auto:<sid>` with a stamp containing `0` → duration_s OMITTED (was
#      the ~1.77B epoch-garbage path).
#   5. `auto:<sid>` with a stamp below the 2020-01-01 epoch floor → OMITTED.
#   6. `auto:<sid>` with a valid recent stamp → duration_s present, ≥0,
#      ≤ the cap.
#   7. Non-numeric literal duration_s → hard error (exit 2). This is the
#      prose-string failure mode; reject at the boundary instead of writing
#      `"~1800"` as a string to the log.
#
# Exit 0 on pass, 1 on any assertion failure.

set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_SCRIPTS=$(cd "$SCRIPT_DIR/../.." && pwd)

TMPROOT=$(mktemp -d -t emit-ascc-fixture.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT"
export ACHILLES_PROJECT="test-project"

LOG_DIR="$HOME/.dev-studio/$ACHILLES_PROJECT/events"
STAMP_DIR="$HOME/.dev-studio/$ACHILLES_PROJECT/.runtime/state/sessions"
mkdir -p "$LOG_DIR" "$STAMP_DIR"

TODAY=$(date -u +%Y-%m-%d)
LOG="$LOG_DIR/$TODAY.jsonl"

assertions=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ -f "$LOG" ] && { printf '--- log tail ---\n' >&2; tail -5 "$LOG" >&2; }
  exit 1
}
assert() {
  assertions=$((assertions + 1))
  if ! eval "$2"; then
    fail "$1 — failed: $2"
  fi
}

# Read the last event's duration_s — returns literal `ABSENT` when the field
# isn't present so the assertion can grep for it distinctly from numeric 0.
last_duration_s() {
  python3 -c '
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
if not p.exists():
    print("NOFILE"); sys.exit(0)
lines = [l for l in p.read_text().splitlines() if l.strip()]
if not lines:
    print("EMPTY"); sys.exit(0)
ev = json.loads(lines[-1])
data = ev.get("data", {})
print(data.get("duration_s", "ABSENT"))
' "$LOG"
}

# ---- 1. Integer form, plausible value ----
"$REPO_SCRIPTS/emit-agent-session-completed.sh" achilles task T-PLAUSIBLE 60 >/dev/null
ds=$(last_duration_s)
assert "plausible integer (60) is present in data" "[ '$ds' = '60' ]"

# ---- 2. Integer form > 86400 cap → OMITTED ----
"$REPO_SCRIPTS/emit-agent-session-completed.sh" achilles task T-OVER-CAP 999999 2>/dev/null >/dev/null
ds=$(last_duration_s)
assert "over-cap integer duration_s omitted (got $ds)" "[ '$ds' = 'ABSENT' ]"

# ---- 3. auto: with no stamp file → OMITTED ----
"$REPO_SCRIPTS/emit-agent-session-completed.sh" achilles task T-NOSTAMP auto:missing-sid 2>/dev/null >/dev/null
ds=$(last_duration_s)
assert "auto: with missing stamp omits duration_s (got $ds)" "[ '$ds' = 'ABSENT' ]"

# ---- 4. auto: with stamp containing 0 → OMITTED (was the ~1.77B bug) ----
echo 0 > "$STAMP_DIR/zero-sid.start"
"$REPO_SCRIPTS/emit-agent-session-completed.sh" achilles task T-ZERO auto:zero-sid 2>/dev/null >/dev/null
ds=$(last_duration_s)
assert "auto: with stamp=0 omits duration_s (got $ds)" "[ '$ds' = 'ABSENT' ]"

# ---- 5. auto: with pre-2020 stamp → OMITTED ----
# 1500000000 = 2017-07-14; below the 2020-01-01 floor.
echo 1500000000 > "$STAMP_DIR/ancient-sid.start"
"$REPO_SCRIPTS/emit-agent-session-completed.sh" achilles task T-ANCIENT auto:ancient-sid 2>/dev/null >/dev/null
ds=$(last_duration_s)
assert "auto: with pre-2020 stamp omits duration_s (got $ds)" "[ '$ds' = 'ABSENT' ]"

# ---- 6. auto: with valid recent stamp → present ----
now=$(date -u +%s)
recent=$(( now - 45 ))
echo "$recent" > "$STAMP_DIR/fresh-sid.start"
"$REPO_SCRIPTS/emit-agent-session-completed.sh" achilles task T-FRESH auto:fresh-sid >/dev/null
ds=$(last_duration_s)
assert "auto: with fresh stamp emits duration_s (got '$ds')" \
  "[ '$ds' != 'ABSENT' ] && [ '$ds' -ge 0 ] && [ '$ds' -le 86400 ]"

# ---- 7. Non-numeric literal → hard error ----
if "$REPO_SCRIPTS/emit-agent-session-completed.sh" achilles task T-PROSE '~1800' 2>/dev/null; then
  fail "non-numeric duration_s ('~1800') should have exited non-zero"
fi
assertions=$((assertions + 1))

# ---- 8. Model telemetry fields are optional but preserved when supplied ----
"$REPO_SCRIPTS/emit-agent-session-completed.sh" achilles task T-MODEL 12 \
  --model-selected claude-sonnet-default \
  --model-fallback-reason fast_turnaround_preference >/dev/null
model_selected=$(python3 -c '
import json, sys, pathlib
lines = [l for l in pathlib.Path(sys.argv[1]).read_text().splitlines() if l.strip()]
print(json.loads(lines[-1]).get("data", {}).get("model_selected", "ABSENT"))
' "$LOG")
model_reason=$(python3 -c '
import json, sys, pathlib
lines = [l for l in pathlib.Path(sys.argv[1]).read_text().splitlines() if l.strip()]
print(json.loads(lines[-1]).get("data", {}).get("model_fallback_reason", "ABSENT"))
' "$LOG")
assert "model_selected is preserved" "[ '$model_selected' = 'claude-sonnet-default' ]"
assert "model_fallback_reason is preserved" "[ '$model_reason' = 'fast_turnaround_preference' ]"

printf 'PASS (%d assertions)\n' "$assertions"
