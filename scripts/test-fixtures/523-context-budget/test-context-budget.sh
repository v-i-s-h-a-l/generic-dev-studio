#!/usr/bin/env bash

set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
CMD="$REPO_ROOT/scripts/v2-context-budget.sh"

"$CMD" --validate >/tmp/v2-context-budget-validate.out 2>/tmp/v2-context-budget-validate.err
grep -q 'v2-context-budget: ok' /tmp/v2-context-budget-validate.err

worker_json=$("$CMD" --resolve --role achilles --invocation chain-worker --format json)
printf '%s\n' "$worker_json" | jq -e '
  .role == "worker" and
  .invocation == "chain-worker" and
  .effective_budget_tokens == 100000 and
  .limiting_dimension == "invocation" and
  .status == "unmeasured"
' >/dev/null

skill_json=$("$CMD" --resolve --role worker --skill swiftui-pro --invocation chain-worker --estimated-tokens 17000 --format json)
printf '%s\n' "$skill_json" | jq -e '
  .effective_budget_tokens == 18000 and
  .limiting_dimension == "skill" and
  .status == "warning" and
  .telemetry_event == "context_budget_resolved"
' >/dev/null

exceeded_json=$("$CMD" --resolve --role reviewer --skill swift-testing-pro --estimated-tokens 15000 --format json)
printf '%s\n' "$exceeded_json" | jq -e '
  .effective_budget_tokens == 14000 and
  .status == "exceeded" and
  .telemetry_event == "context_budget_exceeded"
' >/dev/null

if "$CMD" --resolve --role unknown-host-role >/tmp/v2-context-budget-bad.out 2>/tmp/v2-context-budget-bad.err; then
  printf 'expected unknown role to fail\n' >&2
  exit 1
fi
grep -q 'unknown role or alias' /tmp/v2-context-budget-bad.err

printf 'context-budget fixture: ok\n'
