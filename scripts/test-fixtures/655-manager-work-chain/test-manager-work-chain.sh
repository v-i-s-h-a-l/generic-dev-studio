#!/usr/bin/env bash
# Regression fixture: manager work-chain is a thin discovery/start/resume wrapper.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/manager-work-chain.sh"
TMPROOT=$(mktemp -d -t manager-work-chain.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
if ! command -v yq >/dev/null 2>&1; then
  printf 'SKIP: yq required for manager work-chain fixture\n'
  exit 0
fi

[ -x "$RUN" ] || fail "scripts/manager-work-chain.sh is not executable"

HOME="$TMPROOT/home" "$RUN" >"$TMPROOT/discover.out"
grep -q '# Studio Chain Discovery' "$TMPROOT/discover.out" \
  || fail "bare manager work-chain should default to discovery"
grep -q 'prd-to-chain-automation' "$TMPROOT/discover.out" \
  || fail "discovery should surface the PRD automation chain"

BIN="$TMPROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "Manager work-chain fixture $issue",
  "body": "Exercise work-chain front-door behavior.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/$issue",
  "state": "OPEN"
}
JSON
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

PATH="$BIN:$PATH" HOME="$TMPROOT/home" "$RUN" prd-to-chain-automation --dry-run >"$TMPROOT/plan.out" 2>&1
grep -q '# Studio Chain Plan' "$TMPROOT/plan.out" \
  || fail "named manager work-chain should forward to the runner"
grep -q 'prd-to-chain-automation' "$TMPROOT/plan.out" \
  || fail "named manager work-chain should preserve the chain name"

printf 'PASS: manager work-chain front door\n'
