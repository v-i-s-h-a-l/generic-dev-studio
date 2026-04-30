#!/usr/bin/env bash
# Verifies SessionStart emits timing telemetry and only surfaces budget warnings
# when the configured budget is exceeded.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t session-start-timing.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT="session-start-timing"
export CODEX_PLUGIN_ROOT="$TMPROOT/codex-plugin"
mkdir -p "$CODEX_PLUGIN_ROOT"

out="$TMPROOT/out.json"
STUDIO_SESSION_START_BUDGET_S=999 bash "$ROOT/hooks/session-start" > "$out"
grep -q '"additionalContext"' "$out"
if grep -q 'SessionStart latency warning' "$out"; then
  printf 'FAIL: clean budget emitted warning\n' >&2
  cat "$out" >&2
  exit 1
fi

log="$HOME/.dev-studio/$ACHILLES_PROJECT/events/$(date -u +%Y-%m-%d).jsonl"
jq -e 'select(.event=="session_start_completed" and .data.status=="completed" and .data.duration_s >= 0 and .data.budget_s==999)' "$log" >/dev/null

warn="$TMPROOT/warn.json"
STUDIO_SESSION_START_BUDGET_S=-1 bash "$ROOT/hooks/session-start" > "$warn"
grep -q 'SessionStart latency warning' "$warn"
jq -e 'select(.event=="session_start_completed" and .data.status=="budget_exceeded" and .data.duration_s >= 0 and .data.budget_s==-1)' "$log" >/dev/null

printf 'PASS: session-start timing\n'
