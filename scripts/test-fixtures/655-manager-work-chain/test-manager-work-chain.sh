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
grep -q 'ios-v2-execution' "$TMPROOT/discover.out" \
  || fail "discovery should surface the iOS execution chain"
grep -q '/dev-studio manager work-chain <chain> --dry-run' "$TMPROOT/discover.out" \
  || fail "discovery should surface the preferred preview command contract"
grep -q 'scripts/manager-work-chain.sh' "$TMPROOT/discover.out" \
  || fail "discovery should keep script equivalents for automation"

HOME="$TMPROOT/home" "$RUN" --discover ios-v2-execution >"$TMPROOT/discover-filtered.out"
grep -q 'ios-v2-execution' "$TMPROOT/discover-filtered.out" \
  || fail "filtered manager discovery should surface the named chain"
if grep -q '/dev-studio manager work-chain automation-mode-preference --dry-run' "$TMPROOT/discover-filtered.out"; then
  fail "filtered manager discovery should not list unrelated chains"
fi

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

PATH="$BIN:$PATH" HOME="$TMPROOT/home" "$RUN" ios-v2-execution --dry-run >"$TMPROOT/plan.out" 2>&1
grep -q '# Studio Chain Plan' "$TMPROOT/plan.out" \
  || fail "named manager work-chain dry-run should preview the plan"
grep -q -- '- Execution mode: `attended`' "$TMPROOT/plan.out" \
  || fail "named manager work-chain dry-run should preserve default attended mode"
grep -q 'ios-v2-execution' "$TMPROOT/plan.out" \
  || fail "named manager work-chain should preserve the chain name"

PATH="$BIN:$PATH" HOME="$TMPROOT/home" "$RUN" ios-v2-execution --attended --yes --dry-run >"$TMPROOT/attended.out" 2>&1
grep -q -- '- Execution mode: `attended`' "$TMPROOT/attended.out" \
  || fail "explicit attended manager work-chain should not be rewritten to auto"

printf 'PASS: manager work-chain front door\n'
