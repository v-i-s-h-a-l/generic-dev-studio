#!/usr/bin/env bash
# task-build-debt-gate.sh — Step 1.5 of the Achilles task mode.
#
# Consults the per-project `build_debt_blocked` state flag and decides whether
# to block the task or proceed under `--ignore-build-debt`. Emits the
# `build_debt_blocked` event either way when the flag is present, with
# `override_attempted` distinguishing the two paths. No flag → silent exit 0.
#
# Usage:
#   scripts/task-build-debt-gate.sh [--override]
#
# Exit codes:
#   0  cleared — either no flag, or override applied
#   2  blocked — flag present and no override

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

OVERRIDE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --override) OVERRIDE=1; shift ;;
    *) printf 'error: unknown flag %s\n' "$1" >&2; exit 2 ;;
  esac
done

PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }
ROOT=$(resolve_project_root_for "$PROJECT")
FLAG="$ROOT/.runtime/state/build_debt_blocked"

# Absent flag is the happy path — most dispatches.
[ -f "$FLAG" ] || exit 0

# Event payload shares the counter when the flag file records it; otherwise
# emit with override_attempted alone so the block is still countable.
counter=$(head -n 1 "$FLAG" 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]+$' || echo 0)
[ -z "$counter" ] && counter=0

if [ "$OVERRIDE" -eq 1 ]; then
  printf 'warn: build-debt-blocked; override in effect\n' >&2
  data=$(printf '{"counter":%s,"override_attempted":true}' "$counter")
  emit_event_keyed achilles task build_debt_blocked "" "$data" >/dev/null 2>&1 || true
  exit 0
fi

data=$(printf '{"counter":%s,"override_attempted":false}' "$counter")
emit_event_keyed achilles task build_debt_blocked "" "$data" >/dev/null 2>&1 || true
cat >&2 <<EOF
error: build-debt-blocked flag set at $FLAG.
  Run \`/dev-studio manager sweep-debt\` to work down the counter, or re-invoke with
  \`--ignore-build-debt\` to override this one task.
EOF
exit 2
