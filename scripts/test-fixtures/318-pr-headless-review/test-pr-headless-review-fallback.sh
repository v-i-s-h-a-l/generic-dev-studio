#!/usr/bin/env bash
# Verifies failed reviewer attempts remain visible when a later reviewer passes.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t pr-headless-review-fallback.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'claude fixture help\n'; exit 0 ;;
  *"smoke test"*) printf 'STUDIO_REVIEW_VERDICT=approved\n'; exit 0 ;;
esac
printf 'claude actual review failed\n' >&2
exit 17
SH
chmod +x "$BIN/claude"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'codex fixture help\n'; exit 0 ;;
esac
printf 'codex review summary\n'
printf 'STUDIO_REVIEW_VERDICT=approved\n'
SH
chmod +x "$BIN/codex"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -u

case "$1 $2" in
  "pr view")
    printf '{"number":124,"title":"Fixture PR","url":"https://github.com/owner/repo/pull/124","baseRefName":"main","headRefName":"feature","headRefOid":"def456","author":{"login":"author"},"commits":[{"oid":"def456"}]}\n'
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
SH
chmod +x "$BIN/autopilot"

export PATH="$BIN:$PATH"
export PR_HEADLESS_REVIEW_AUTOPILOT="$BIN/autopilot"
export AUTOPILOT_LOG="$TMPROOT/autopilot.log"
export HOME="$TMPROOT/home"
export CODEX_HOME="$HOME/.codex"
export CLAUDE_REVIEWER_CONFIG_DIR="$TMPROOT/.claude-reviewer"
mkdir -p "$CODEX_HOME"

out="$TMPROOT/out"
if ! bash "$ROOT/scripts/pr-headless-review.sh" 124 --method auto >"$out" 2>"$out.err"; then
  printf 'FAIL: fallback review should have succeeded\n' >&2
  sed -n '1,120p' "$out.err" >&2 || true
  exit 1
fi

if ! grep -q 'PR_REVIEW_HOST=codex-reviewer' "$out"; then
  printf 'FAIL: fallback did not select codex-reviewer\n' >&2
  cat "$out" >&2
  exit 1
fi
if ! grep -q 'PR_REVIEW_FALLBACK_FROM=claude-reviewer' "$out"; then
  printf 'FAIL: fallback source missing from stdout\n' >&2
  cat "$out" >&2
  exit 1
fi
if ! grep -q -- '--fallback-from claude-reviewer' "$AUTOPILOT_LOG"; then
  printf 'FAIL: fallback source missing from autopilot args\n' >&2
  cat "$AUTOPILOT_LOG" >&2
  exit 1
fi
if ! grep -q -- '--fallback-failures claude-reviewer: claude actual review failed' "$AUTOPILOT_LOG"; then
  printf 'FAIL: fallback failure detail missing from autopilot args\n' >&2
  cat "$AUTOPILOT_LOG" >&2
  exit 1
fi

printf 'PASS: PR headless review fallback visibility\n'
