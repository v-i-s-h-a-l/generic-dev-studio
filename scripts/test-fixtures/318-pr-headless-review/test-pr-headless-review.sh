#!/usr/bin/env bash
# Verifies the headless PR review driver runs an eligible reviewer and hands
# the parsed verdict to pr-autopilot.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t pr-headless-review.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'codex fixture help\n'; exit 0 ;;
esac
session_dir="$CODEX_HOME/sessions/2026/04/30"
mkdir -p "$session_dir"
cat > "$session_dir/review-fixture.jsonl" <<EOF
{"timestamp":"2026-04-30T15:00:00Z","type":"session_meta","payload":{"id":"fixture-session","timestamp":"2026-04-30T15:00:00Z","cwd":"$(pwd)","originator":"codex-tui","cli_version":"fixture"}}
{"timestamp":"2026-04-30T15:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1234,"cached_input_tokens":432,"output_tokens":567,"reasoning_output_tokens":0,"total_tokens":1801},"last_token_usage":{"input_tokens":1234,"cached_input_tokens":432,"output_tokens":567,"reasoning_output_tokens":0,"total_tokens":1801}}}}
EOF
printf 'review summary\n'
printf 'STUDIO_REVIEW_VERDICT=approved_with_fixes\n'
[ -n "${REVIEW_PAYLOAD:-}" ] && [ -f "$REVIEW_PAYLOAD" ] || exit 3
[ ! -f "$HOME/.config/gh/hosts.yml" ] || { printf 'reviewer inherited caller HOME\n' >&2; exit 5; }
[ -n "${CODEX_HOME:-}" ] && [ -d "$CODEX_HOME" ] || { printf 'reviewer missing explicit CODEX_HOME\n' >&2; exit 6; }
case "${GH_TOKEN:-}${GITHUB_TOKEN:-}${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}" in
  "") ;;
  *) printf 'secret leaked into reviewer env\n' >&2; exit 4 ;;
esac
SH
chmod +x "$BIN/codex"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -u

case "$1 $2" in
  "pr view")
    case " $* " in
      *" --jq .number "*|*" --jq "*) printf '123\n' ;;
      *) printf '{"number":123,"title":"Fixture PR","url":"https://github.com/owner/repo/pull/123","baseRefName":"main","headRefName":"feature","headRefOid":"abc123","author":{"login":"author"},"commits":[{"oid":"abc123"}]}\n' ;;
    esac
    ;;
  "pr diff")
    printf 'diff --git a/file b/file\n+change\n'
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN/gh"

cat > "$BIN/autopilot" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${AUTOPILOT_LOG:?}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary-file) summary="${2:?}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${summary:-}" ] && grep -q 'STUDIO_REVIEW_VERDICT=approved_with_fixes' "$summary"
SH
chmod +x "$BIN/autopilot"

export PATH="$BIN:$PATH"
export PR_HEADLESS_REVIEW_AUTOPILOT="$BIN/autopilot"
export AUTOPILOT_LOG="$TMPROOT/autopilot.log"
export GH_TOKEN="must-not-leak"
export GITHUB_TOKEN="must-not-leak"
export OPENAI_API_KEY="must-not-leak"
export ANTHROPIC_API_KEY="must-not-leak"
export HOME="$TMPROOT/caller-home"
mkdir -p "$HOME/.config/gh"
printf 'github.com: token\n' > "$HOME/.config/gh/hosts.yml"
mkdir -p "$HOME/.codex"

failures=0
assert() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

out="$TMPROOT/out.txt"
bash "$ROOT/scripts/pr-headless-review.sh" 123 --review-host codex-reviewer --method auto > "$out" 2>"$out.err"
rc=$?
EVENT_LOG=$(find "$HOME/.dev-studio" -type f -path '*/events/2026-04-30.jsonl' | head -1)

assert "headless review exits zero" "[ '$rc' -eq 0 ]"
assert "review host reported" "grep -q 'PR_REVIEW_HOST=codex-reviewer' '$out'"
assert "verdict parsed" "grep -q 'PR_REVIEW_VERDICT=approved_with_fixes' '$out'"
assert "autopilot receives verdict" "grep -q -- '--verdict approved_with_fixes' '$AUTOPILOT_LOG'"
assert "autopilot receives review host" "grep -q -- '--review-host codex-reviewer' '$AUTOPILOT_LOG'"
assert "autopilot receives reviewed head" "grep -q -- '--expected-head-sha abc123' '$AUTOPILOT_LOG'"
assert "autopilot receives method" "grep -q -- '--method auto' '$AUTOPILOT_LOG'"
assert "review event carries tokens" "[ -n \"$EVENT_LOG\" ] && jq -e 'select(.event==\"pr_review_completed\" and .data.tokens.input == 1234 and .data.tokens.output == 567 and .data.tokens.cache_read == 432)' \"$EVENT_LOG\" >/dev/null"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s)\n' "$failures" >&2
  sed -n '1,120p' "$out.err" >&2 || true
  exit 1
fi

printf 'PASS: PR headless review driver\n'
