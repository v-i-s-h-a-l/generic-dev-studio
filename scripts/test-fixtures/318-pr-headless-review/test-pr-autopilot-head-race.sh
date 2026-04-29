#!/usr/bin/env bash
# Verifies pr-autopilot refuses to gate a PR when the reviewed head is stale.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t pr-autopilot-head-race.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'codex fixture help\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$BIN/codex"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -u

case "$1 $2" in
  "pr view")
    printf '{"headRefOid":"new456","url":"https://github.com/owner/repo/pull/123"}\n'
    ;;
  "pr comment")
    printf 'unexpected comment for stale review head\n' >&2
    exit 7
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN/gh"

export PATH="$BIN:$PATH"

summary="$TMPROOT/summary.md"
printf 'STUDIO_REVIEW_VERDICT=approved\n' > "$summary"

if bash "$ROOT/scripts/pr-autopilot.sh" 123 \
    --verdict approved \
    --review-host codex-reviewer \
    --summary-file "$summary" \
    --expected-head-sha old123 \
    >"$TMPROOT/out" 2>"$TMPROOT/err"; then
  printf 'FAIL: stale reviewed head was accepted\n' >&2
  exit 1
fi

if ! grep -q 'reviewed HEAD_SHA=old123 but current HEAD_SHA=new456' "$TMPROOT/err"; then
  printf 'FAIL: stale-head error did not explain the mismatch\n' >&2
  sed -n '1,80p' "$TMPROOT/err" >&2 || true
  exit 1
fi

printf 'PASS: PR autopilot stale-head race guard\n'
