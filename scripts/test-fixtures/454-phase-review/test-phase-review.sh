#!/usr/bin/env bash
# Verifies phase-review.sh uses the reviewer wrapper instead of raw Claude.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t phase-review.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'claude fixture help\n'; exit 0 ;;
esac

case " $* " in
  *" -p "*|*" --print "*) ;;
  *) printf 'claude reviewer was not headless\n' >&2; exit 3 ;;
esac
case " $* " in
  *" --permission-mode dontAsk "*) ;;
  *) printf 'claude reviewer can still prompt\n' >&2; exit 4 ;;
esac
case " $* " in
  *" --setting-sources project "*) ;;
  *) printf 'claude reviewer inherited user/local settings\n' >&2; exit 5 ;;
esac
case " $* " in
  *" --disable-slash-commands "*) ;;
  *) printf 'claude reviewer inherited slash commands\n' >&2; exit 6 ;;
esac
case " $* " in
  *" --no-session-persistence "*) ;;
  *) printf 'claude reviewer persisted session state\n' >&2; exit 7 ;;
esac
case " $* " in
  *" --strict-mcp-config "*) ;;
  *) printf 'claude reviewer inherited MCP config\n' >&2; exit 8 ;;
esac
case " $* " in
  *" --tools=Read,Grep,Glob "*) ;;
  *) printf 'claude reviewer did not use read-only tools\n' >&2; exit 9 ;;
esac

[ -n "${CLAUDE_CONFIG_DIR:-}" ] || { printf 'missing CLAUDE_CONFIG_DIR\n' >&2; exit 10; }
case "${CLAUDE_CONFIG_DIR:-}" in
  */.claude-reviewer) ;;
  *) printf 'bad CLAUDE_CONFIG_DIR: %s\n' "$CLAUDE_CONFIG_DIR" >&2; exit 11 ;;
esac
[ -n "${CLAUDE_REVIEWER_HOME:-}" ] || { printf 'missing CLAUDE_REVIEWER_HOME\n' >&2; exit 12; }
[ "$HOME" = "$CLAUDE_REVIEWER_HOME" ] || { printf 'HOME did not use reviewer auth root\n' >&2; exit 13; }
[ -n "${REVIEW_PAYLOAD:-}" ] && [ -f "$REVIEW_PAYLOAD" ] || { printf 'missing review payload\n' >&2; exit 14; }
[ ! -f "$HOME/.config/gh/hosts.yml" ] || { printf 'reviewer inherited caller HOME\n' >&2; exit 15; }
case "${GH_TOKEN:-}${GITHUB_TOKEN:-}${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}" in
  "") ;;
  *) printf 'secret leaked into reviewer env\n' >&2; exit 16 ;;
esac

case " $* " in
  *"STUDIO_REVIEW_VERDICT"*) printf 'STUDIO_REVIEW_VERDICT=approved\n' ;;
  *)
    case " $* " in
      *"Review ask: what's still wrong?"*) ;;
      *) printf 'phase artifact content was not inlined into prompt\n' >&2; exit 17 ;;
    esac
    printf 'Verdict: clean; nothing fatal.\n'
    ;;
esac
SH
chmod +x "$BIN/claude"

export PATH="$BIN:$PATH"
export HOME="$TMPROOT/caller-home"
export CLAUDE_REVIEWER_HOME="$TMPROOT/reviewer-home"
export CLAUDE_REVIEWER_CONFIG_DIR="$CLAUDE_REVIEWER_HOME/.claude-reviewer"
export GH_TOKEN="must-not-leak"
export GITHUB_TOKEN="must-not-leak"
export OPENAI_API_KEY="must-not-leak"
export ANTHROPIC_API_KEY="must-not-leak"

mkdir -p "$HOME/.config/gh" "$CLAUDE_REVIEWER_CONFIG_DIR"
printf 'github.com: token\n' > "$HOME/.config/gh/hosts.yml"

input="$TMPROOT/plan.md"
output="$TMPROOT/review.md"
cat > "$input" <<'MD'
# Phase plan

Review ask: what's still wrong?
MD

out="$TMPROOT/phase-review.out"
if ! bash "$ROOT/scripts/phase-review.sh" \
  --review-host claude-reviewer \
  --kind plan \
  --input "$input" \
  --output "$output" >"$out" 2>"$out.err"; then
  sed -n '1,120p' "$out" >&2 || true
  sed -n '1,120p' "$out.err" >&2 || true
  sed -n '1,120p' "$output" >&2 || true
  sed -n '1,120p' "$output.err" >&2 || true
  exit 1
fi

grep -q 'PHASE_REVIEW_HOST=claude-reviewer' "$out"
grep -q 'PHASE_REVIEW_OUTPUT=' "$out"
grep -q 'nothing fatal' "$output"
[ ! -s "$output.err" ]

printf 'PASS: phase-review uses smoke-eligible Claude reviewer wrapper\n'
