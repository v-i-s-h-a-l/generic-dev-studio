#!/usr/bin/env bash
# Verifies cross-host-required mode refuses same-family review when an alternate
# smoke-passing reviewer exists, unless the human-approved bypass is recorded.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t pr-headless-review-cross-host.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'claude fixture help\n'; exit 0 ;;
esac
printf 'STUDIO_REVIEW_VERDICT=approved\n'
SH
chmod +x "$BIN/claude"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'codex fixture help\n'; exit 0 ;;
esac
printf 'STUDIO_REVIEW_VERDICT=approved\n'
SH
chmod +x "$BIN/codex"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -u

case "$1 $2" in
  "pr view")
    printf '{"number":123,"title":"Fixture PR","url":"https://github.com/owner/repo/pull/123","baseRefName":"main","headRefName":"feature","headRefOid":"abc123","author":{"login":"author"},"commits":[{"oid":"abc123"}]}\n'
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
export STUDIO_PARENT_HOST="codex"
mkdir -p "$CODEX_HOME"

if bash "$ROOT/scripts/pr-headless-review.sh" 123 \
    --review-host codex-reviewer \
    --require-cross-host-when-available \
    >"$TMPROOT/blocked.out" 2>"$TMPROOT/blocked.err"; then
  printf 'FAIL: same-family review was accepted without bypass\n' >&2
  exit 1
fi
if ! grep -q 'cross-host review required' "$TMPROOT/blocked.err"; then
  printf 'FAIL: same-family refusal did not explain cross-host requirement\n' >&2
  sed -n '1,80p' "$TMPROOT/blocked.err" >&2 || true
  exit 1
fi

if ! bash "$ROOT/scripts/pr-headless-review.sh" 123 \
    --review-host codex-reviewer \
    --require-cross-host-when-available \
    --allow-same-host-review \
    --user-approved-bypass https://github.com/owner/repo/issues/1 \
    >"$TMPROOT/bypass.out" 2>"$TMPROOT/bypass.err"; then
  printf 'FAIL: user-approved same-host bypass should have succeeded\n' >&2
  sed -n '1,120p' "$TMPROOT/bypass.err" >&2 || true
  exit 1
fi
if ! grep -q -- '--cross-host false' "$AUTOPILOT_LOG"; then
  printf 'FAIL: bypassed review did not report cross-host=false\n' >&2
  cat "$AUTOPILOT_LOG" >&2
  exit 1
fi
if ! grep -q -- '--cross-host-bypass-url https://github.com/owner/repo/issues/1' "$AUTOPILOT_LOG"; then
  printf 'FAIL: cross-host bypass URL missing from autopilot args\n' >&2
  cat "$AUTOPILOT_LOG" >&2
  exit 1
fi

printf 'PASS: PR headless review cross-host policy\n'
