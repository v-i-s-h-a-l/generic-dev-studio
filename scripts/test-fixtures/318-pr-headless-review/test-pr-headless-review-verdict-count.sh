#!/usr/bin/env bash
# Verifies the headless reviewer must emit exactly one verdict line.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t pr-headless-review-verdict.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'codex fixture help\n'; exit 0 ;;
esac
printf 'STUDIO_REVIEW_VERDICT=blocked\n'
printf 'STUDIO_REVIEW_VERDICT=approved\n'
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
printf 'autopilot must not run for ambiguous verdicts\n' >&2
exit 6
SH
chmod +x "$BIN/autopilot"

export PATH="$BIN:$PATH"
export PR_HEADLESS_REVIEW_AUTOPILOT="$BIN/autopilot"
export HOME="$TMPROOT/caller-home"
mkdir -p "$HOME/.codex"

if bash "$ROOT/scripts/pr-headless-review.sh" 123 --review-host codex-reviewer --method auto \
    >"$TMPROOT/out" 2>"$TMPROOT/err"; then
  printf 'FAIL: multiple verdict lines were accepted\n' >&2
  exit 1
fi

if ! grep -q 'must emit exactly one STUDIO_REVIEW_VERDICT line' "$TMPROOT/err"; then
  printf 'FAIL: verdict-count error did not explain the mismatch\n' >&2
  sed -n '1,80p' "$TMPROOT/err" >&2 || true
  exit 1
fi

printf 'PASS: PR headless review verdict-count guard\n'
