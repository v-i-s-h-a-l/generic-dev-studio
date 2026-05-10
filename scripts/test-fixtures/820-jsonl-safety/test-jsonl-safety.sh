#!/usr/bin/env bash
# test-jsonl-safety.sh — fixture for #820 items 7.1 + 7.2 + 7.4.
#
# Exercises:
#   - jsonl-merge.sh: happy merge with ts sort + idempotency-key dedupe
#   - jsonl-merge.sh: control-character payload survives (the regression class)
#   - jsonl-merge.sh: refuses to write under <project>/events/
#   - jsonl-merge.sh: refuses to lose records (parse-fail input → exit 3)
#   - jsonl-merge.sh: keeps a .bak under runtime-global logs
#   - lint-jsonl-merge.sh: flags `jq -s sort_by` shape, ignores benign jq -s

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
MERGE="$ROOT/scripts/jsonl-merge.sh"
LINT="$ROOT/scripts/lint-jsonl-merge.sh"
TMPROOT=$(mktemp -d -t jsonl-safety.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
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

# ─── jsonl-merge.sh ───
mkdir -p "$TMPROOT/m"
A="$TMPROOT/m/a.jsonl"
B="$TMPROOT/m/b.jsonl"
OUT="$TMPROOT/m/merged.jsonl"
cat > "$A" <<'JSON'
{"ts":"2026-05-10T10:00:00Z","idempotency_key":"k1","msg":"alpha"}
{"ts":"2026-05-10T10:02:00Z","idempotency_key":"k2","msg":"beta"}
JSON
cat > "$B" <<'JSON'
{"ts":"2026-05-10T10:01:00Z","idempotency_key":"k3","msg":"gamma"}
{"ts":"2026-05-10T10:00:00Z","idempotency_key":"k1","msg":"alpha-dup"}
JSON

"$MERGE" "$OUT" "$A" "$B" >/dev/null 2>&1
assert "happy merge produces 3 deduped records (k1 dup folded)" \
  '[ "$(wc -l < "$OUT" | tr -d " ")" = "3" ]'
assert "happy merge sorts by ts" \
  'head -1 "$OUT" | grep -q "10:00:00"'
assert "happy merge dedupes by idempotency_key (single k1)" \
  '[ "$(grep -c "\"idempotency_key\":\"k1\"" "$OUT")" = "1" ]'

# Control-char payload — the regression class. jq -s would die here; python
# json handles it (serialized \n).
CTRL="$TMPROOT/m/ctrl.jsonl"
printf '{"ts":"2026-05-10T11:00:00Z","msg":"line1\\nline2","idempotency_key":"c1"}\n' > "$CTRL"
"$MERGE" "$TMPROOT/m/ctrl-out.jsonl" "$CTRL" >/dev/null 2>&1
assert "control-char payload survives merge" \
  '[ "$(wc -l < "$TMPROOT/m/ctrl-out.jsonl" | tr -d " ")" = "1" ]'

# Events refusal.
mkdir -p "$HOME/.dev-studio/proj1/events"
EV_OUT="$HOME/.dev-studio/proj1/events/2026-05-10.jsonl"
"$MERGE" "$EV_OUT" "$A" 2>"$TMPROOT/ev.err"
ev_rc=$?
assert "events path refused with exit 1" \
  '[ "$ev_rc" -eq 1 ]'
assert "events refusal mentions append-only" \
  'grep -q "append-only" "$TMPROOT/ev.err"'
assert "events refusal does not create the output" \
  '! [ -f "$EV_OUT" ]'

# Parse-fail on malformed input.
BAD="$TMPROOT/m/bad.jsonl"
printf '{not valid json\n' > "$BAD"
"$MERGE" "$TMPROOT/m/bad-out.jsonl" "$BAD" 2>/dev/null
bad_rc=$?
assert "parse failure exits 3" '[ "$bad_rc" -eq 3 ]'
assert "parse failure leaves no output" \
  '! [ -f "$TMPROOT/m/bad-out.jsonl" ]'

# Bak retention.
echo '{"ts":"2026-05-10T09:00:00Z","msg":"old"}' > "$OUT"
"$MERGE" "$OUT" "$A" >/dev/null 2>&1
assert "bak written under runtime-global logs/jsonl-merge/" \
  '[ -n "$(ls "$HOME/.dev-studio/.runtime/logs/jsonl-merge"/*.bak 2>/dev/null)" ]'

# ─── lint-jsonl-merge.sh ───
LINT_REPO="$TMPROOT/lint-repo"
mkdir -p "$LINT_REPO/scripts"
cat > "$LINT_REPO/scripts/dangerous.sh" <<'SH'
#!/usr/bin/env bash
cat $a $b | jq -c -s 'sort_by(.ts) | unique | .[]' > merged.jsonl
SH
cat > "$LINT_REPO/scripts/benign.sh" <<'SH'
#!/usr/bin/env bash
jq -s '.' a.json b.json
echo $items | jq -r '[.x] | group_by(.y)' | paste -sd, -
SH
LINT_JSONL_MERGE_REPO_ROOT="$LINT_REPO" bash "$LINT" --strict > "$TMPROOT/lint.out" 2>&1
lint_rc=$?
assert "lint flags dangerous jq -s sort_by" \
  'grep -q "scripts/dangerous.sh" "$TMPROOT/lint.out"'
assert "lint does NOT flag benign jq -s . or jq -r with downstream paste -sd" \
  '! grep -q "scripts/benign.sh" "$TMPROOT/lint.out"'
assert "lint exits non-zero on dangerous match" '[ "$lint_rc" -eq 1 ]'

# Allow annotation suppresses the flag.
cat > "$LINT_REPO/scripts/annotated.sh" <<'SH'
#!/usr/bin/env bash
# lint-jsonl-merge:allow next-line — historical comparison, not a real merge.
result=$(cat a b | jq -s 'sort_by(.ts) | unique')
SH
LINT_JSONL_MERGE_REPO_ROOT="$LINT_REPO" bash "$LINT" --strict > "$TMPROOT/lint2.out" 2>&1
assert "allow annotation suppresses lint" \
  '! grep -q "scripts/annotated.sh" "$TMPROOT/lint2.out"'

if [ "$fail" -gt 0 ]; then
  printf 'FAIL: %d test(s) failed\n' "$fail" >&2
  exit 1
fi
printf 'PASS: jsonl-safety (%d/%d)\n' "$pass" "$pass"
