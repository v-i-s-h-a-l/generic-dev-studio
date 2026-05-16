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
  *"outcome-review artifact"*)
    printf 'Your organization has disabled Claude subscription access for Claude Code · 403\n' >&2
    exit 17
    ;;
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

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'codex fixture help\n'; exit 0 ;;
esac
[ -n "${CODEX_HOME:-}" ] || { printf 'missing CODEX_HOME\n' >&2; exit 20; }
[ -n "${REVIEW_PAYLOAD:-}" ] && [ -f "$REVIEW_PAYLOAD" ] || { printf 'missing review payload\n' >&2; exit 21; }
case "${GH_TOKEN:-}${GITHUB_TOKEN:-}${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}" in
  "") ;;
  *) printf 'secret leaked into codex reviewer env\n' >&2; exit 22 ;;
esac
case " $* " in
  *"codex reviewer outage"*) printf 'codex reviewer outage: no usable verdict\n' >&2; exit 23 ;;
esac
case " $* " in
  *"STUDIO_REVIEW_VERDICT"*) printf 'STUDIO_REVIEW_VERDICT=approved\n' ;;
  *) printf 'PHASE_REVIEW_VERDICT=clean\ncodex fallback found nothing fatal.\n' ;;
esac
SH
chmod +x "$BIN/codex"

export PATH="$BIN:$PATH"
export HOME="$TMPROOT/caller-home"
export CODEX_REVIEWER_HOME="$TMPROOT/codex-reviewer-home"
export CLAUDE_REVIEWER_HOME="$TMPROOT/reviewer-home"
export CLAUDE_REVIEWER_CONFIG_DIR="$CLAUDE_REVIEWER_HOME/.claude-reviewer"
export GH_TOKEN="must-not-leak"
export GITHUB_TOKEN="must-not-leak"
export OPENAI_API_KEY="must-not-leak"
export ANTHROPIC_API_KEY="must-not-leak"

mkdir -p "$HOME/.config/gh" "$CODEX_REVIEWER_HOME" "$CLAUDE_REVIEWER_CONFIG_DIR"
printf 'github.com: token\n' > "$HOME/.config/gh/hosts.yml"

resolved_codex_home=$(STUDIO_CONTEXT_HOST_PROFILE=codex-reviewer bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_get auth_home delegated-host-spawn")
[ "$resolved_codex_home" = "$CODEX_REVIEWER_HOME" ] || {
  printf 'fixture resolved codex auth home incorrectly: %s\n' "$resolved_codex_home" >&2
  exit 1
}

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
grep -q 'PHASE_REVIEW_VERDICT=clean' "$out"
grep -q 'PHASE_REVIEW_MODEL_ID=claude-sonnet-4-6' "$out"
grep -q 'PHASE_REVIEW_REASONING_EFFORT=high' "$out"
grep -q 'nothing fatal' "$output"
[ ! -s "$output.err" ]

fallback_output="$TMPROOT/fallback-review.md"
fallback_out="$TMPROOT/phase-review-fallback.out"
if ! bash "$ROOT/scripts/phase-review.sh" \
  --review-host claude-reviewer \
  --kind outcome \
  --input "$input" \
  --output "$fallback_output" >"$fallback_out" 2>"$fallback_out.err"; then
  sed -n '1,120p' "$fallback_out" >&2 || true
  sed -n '1,120p' "$fallback_out.err" >&2 || true
  sed -n '1,120p' "$fallback_output" >&2 || true
  sed -n '1,120p' "$fallback_output.err" >&2 || true
  exit 1
fi

grep -q 'PHASE_REVIEW_FALLBACK_FROM=claude-reviewer' "$fallback_out"
grep -q 'PHASE_REVIEW_FALLBACK_TO=codex-reviewer' "$fallback_out"
grep -q 'PHASE_REVIEW_FALLBACK_REASON=claude_subscription_403' "$fallback_out"
grep -q 'PHASE_REVIEW_HOST=codex-reviewer' "$fallback_out"
grep -q 'PHASE_REVIEW_VERDICT=clean' "$fallback_out"
grep -q 'codex fallback found nothing fatal' "$fallback_output"
grep -q 'disabled Claude subscription access' "$fallback_output.err.claude-reviewer"
[ ! -s "$fallback_output.err" ]

disabled_output="$TMPROOT/disabled-fallback-review.md"
disabled_out="$TMPROOT/phase-review-disabled-fallback.out"
if STUDIO_DISABLE_PHASE_REVIEW_CLAUDE_403_FALLBACK=1 bash "$ROOT/scripts/phase-review.sh" \
  --review-host claude-reviewer \
  --kind outcome \
  --input "$input" \
  --output "$disabled_output" >"$disabled_out" 2>"$disabled_out.err"; then
  printf 'FAIL: disabled Claude 403 fallback should preserve the failure\n' >&2
  exit 1
fi
grep -q 'reviewer command failed for claude-reviewer' "$disabled_out.err"
if grep -q 'PHASE_REVIEW_HOST=codex-reviewer' "$disabled_out"; then
  printf 'FAIL: disabled fallback still selected codex-reviewer\n' >&2
  exit 1
fi

degraded_input="$TMPROOT/degraded-plan.md"
degraded_output="$TMPROOT/degraded-review.md"
degraded_out="$TMPROOT/phase-review-degraded.out"
cat > "$degraded_input" <<'MD'
# Phase plan

Review ask: what's still wrong?
codex reviewer outage
MD

if ! STUDIO_PARENT_HOST=claude-code bash "$ROOT/scripts/phase-review.sh" \
  --review-host codex-reviewer \
  --kind plan \
  --input "$degraded_input" \
  --output "$degraded_output" >"$degraded_out" 2>"$degraded_out.err"; then
  sed -n '1,160p' "$degraded_out" >&2 || true
  sed -n '1,160p' "$degraded_out.err" >&2 || true
  sed -n '1,160p' "$degraded_output" >&2 || true
  sed -n '1,160p' "$degraded_output.err" >&2 || true
  exit 1
fi

grep -q 'PHASE_REVIEW_FALLBACK_FROM=codex-reviewer' "$degraded_out"
grep -q 'PHASE_REVIEW_FALLBACK_TO=claude-reviewer' "$degraded_out"
grep -q 'PHASE_REVIEW_FALLBACK_REASON=reviewer_command_failed' "$degraded_out"
grep -q 'PHASE_REVIEW_HOST=claude-reviewer' "$degraded_out"
grep -q 'PHASE_REVIEW_DEGRADED=1' "$degraded_out"
grep -q 'PHASE_REVIEW_CROSS_HOST_SATISFIED=false' "$degraded_out"
grep -q 'PHASE_REVIEW_NEXT_CROSS_HOST_RETRY=next_boundary' "$degraded_out"
grep -q 'codex reviewer outage' "$degraded_output.err.codex-reviewer"
grep -q 'nothing fatal' "$degraded_output"

printf 'PASS: phase-review uses reviewer wrapper and handles degraded fallback\n'
