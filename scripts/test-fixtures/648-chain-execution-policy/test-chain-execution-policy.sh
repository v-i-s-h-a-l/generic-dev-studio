#!/usr/bin/env bash
# Verifies chain review gates, retry policy, and escalation mode are explicit.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-execution-policy.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "Execution policy fixture $issue",
  "body": "Exercise review, retry, and escalation policy.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/$issue",
  "state": "OPEN"
}
JSON
  exit 0
fi

if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

manifest="$TMPROOT/policy.yaml"
cat > "$manifest" <<'YAML'
schema_version: 1
chains:
  - name: policy-a
    base: main
    branch: feature/policy-a
    host: codex
    phase_review: required
    issues: [648]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" STUDIO_CHAIN_RETRY_LIMIT=3 STUDIO_CHAIN_RETRY_BACKOFF_SEC=0 \
  "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --unattended --dry-run > "$TMPROOT/unattended.out" 2>&1

grep -q -- '- Execution mode: `unattended`' "$TMPROOT/unattended.out" || {
  printf 'missing unattended execution mode\n' >&2
  cat "$TMPROOT/unattended.out" >&2
  exit 1
}
grep -q -- 'Retry policy: auto retry retryable operations up to `3` time(s), backoff `0s`' "$TMPROOT/unattended.out" || {
  printf 'missing finite retry policy\n' >&2
  cat "$TMPROOT/unattended.out" >&2
  exit 1
}
grep -q -- 'issue plan phase review before worker launch' "$TMPROOT/unattended.out" || {
  printf 'missing issue plan review gate\n' >&2
  cat "$TMPROOT/unattended.out" >&2
  exit 1
}
grep -q -- 'issue outcome phase review over diff and test/lint/build evidence' "$TMPROOT/unattended.out" || {
  printf 'missing outcome/test evidence review gate\n' >&2
  cat "$TMPROOT/unattended.out" >&2
  exit 1
}
grep -q -- 'final chain PR headless review before merge' "$TMPROOT/unattended.out" || {
  printf 'missing final PR review gate\n' >&2
  cat "$TMPROOT/unattended.out" >&2
  exit 1
}
if grep -Eiq 'should we continue|continue\\?' "$TMPROOT/unattended.out"; then
  printf 'unattended dry-run emitted a routine continuation prompt\n' >&2
  cat "$TMPROOT/unattended.out" >&2
  exit 1
fi

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$manifest" > "$TMPROOT/attended.out" 2>&1
grep -q -- '- Execution mode: `attended`' "$TMPROOT/attended.out" || {
  printf 'missing default attended mode\n' >&2
  cat "$TMPROOT/attended.out" >&2
  exit 1
}
grep -q -- 'attended prompts are reserved for review-needed, human-needed, or fatal blockers' "$TMPROOT/attended.out" || {
  printf 'attended mode does not state focused escalation policy\n' >&2
  cat "$TMPROOT/attended.out" >&2
  exit 1
}

if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --auto "$manifest" --attended > "$TMPROOT/auto-attended.out" 2>&1; then
  printf '--auto --attended unexpectedly passed\n' >&2
  cat "$TMPROOT/auto-attended.out" >&2
  exit 1
fi
grep -q -- '--auto is unattended' "$TMPROOT/auto-attended.out" || {
  printf '--auto --attended failure did not explain the mode boundary\n' >&2
  cat "$TMPROOT/auto-attended.out" >&2
  exit 1
}

AUTH_FAIL_BIN="$TMPROOT/auth-fail-bin"
AUTH_FAIL_HOME="$TMPROOT/auth-fail-home"
mkdir -p "$AUTH_FAIL_BIN" "$AUTH_FAIL_HOME"
cat > "$AUTH_FAIL_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "Execution policy fixture $issue",
  "body": "Exercise retry exhaustion.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/$issue",
  "state": "OPEN"
}
JSON
  exit 0
fi

if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  exit 42
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$AUTH_FAIL_BIN/gh"

if PATH="$AUTH_FAIL_BIN:$PATH" HOME="$AUTH_FAIL_HOME" STUDIO_CHAIN_RETRY_LIMIT=1 STUDIO_CHAIN_RETRY_BACKOFF_SEC=0 \
  "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --unattended --yes > "$TMPROOT/auth-fail.out" 2>&1; then
  printf 'auth failure unexpectedly passed\n' >&2
  cat "$TMPROOT/auth-fail.out" >&2
  exit 1
fi
halt_file=$(find "$AUTH_FAIL_HOME/.dev-studio/generic-dev-studio/chain-runs" -path '*/halt-records/*.json' -type f | head -1)
[ -n "$halt_file" ] || {
  printf 'auth failure did not write a halt record\n' >&2
  cat "$TMPROOT/auth-fail.out" >&2
  exit 1
}
jq -e '
  .reason_id == "github_auth_unavailable" and
  .halt_class == "retryable" and
  .retry_policy.auto_retry_limit == 1 and
  .retry_policy.exhausted == true and
  .escalation.routine_continue_prompt == false
' "$halt_file" >/dev/null || {
  printf 'auth failure halt did not preserve retry/escalation policy\n' >&2
  cat "$halt_file" >&2
  exit 1
}

printf 'PASS: chain execution policy\n'
