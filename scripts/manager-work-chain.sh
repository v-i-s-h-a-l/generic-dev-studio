#!/usr/bin/env bash
# manager-work-chain.sh — repo-side front door for work-chain discovery/start/resume.
#
# This stays thin on purpose: /dev-studio manager shapes intent, then delegates
# the actual execution and resumable-run machinery to studio-chain-runner.sh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
RUNNER="$SCRIPT_DIR/studio-chain-runner.sh"
PLAN_CHAIN="$SCRIPT_DIR/manager-plan-chain.sh"

has_explicit_mode_flag() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --auto|--auto=*|--discover|--list|--resume|--resume=*|--doctor|--doctor=*|--format|--format=*|--public-safe|--explain-next|--explain-next=*|--attended|--unattended|--dry-run|--yes|--no-confirm)
        return 0
        ;;
    esac
  done
  return 1
}

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/manager-work-chain.sh [<manifest|chain-name|chain-id>] [runner-flags...]
  scripts/manager-work-chain.sh --from-plan <task-graph|planner-output> [plan-chain-flags...]

When no chain is named, this defaults to discovery so the manager front door
can suggest runnable chains and resumable runs. Named chains default to
unattended supervisor selection through scripts/studio-chain-runner.sh --auto.
Use --discover [<manifest|chain-name|chain-id>] for filtered, non-mutating discovery.
Chain IDs are accepted anywhere a chain name is accepted.
Use --from-plan to route a reviewed planner/task-graph artifact through the
manager plan-chain workflow, then launch the generated issue-backed chain
unattended by default. Pass --plan-only to stop after manifest creation, or
--interactive to run the generated chain in attended mode.
Use --doctor <run_id> for a read-only chain recovery recommendation.
All runner flags are passed through to scripts/studio-chain-runner.sh.

Preferred user-facing entrypoint:
  /dev-studio manager work-chain [<manifest|chain-name|chain-id>] [runner-flags...]
EOF
  exit 2
}

if [ "$#" -eq 0 ]; then
  exec "$RUNNER" --discover
fi

case "$1" in
  -h|--help) usage ;;
  --from-plan)
    shift
    exec "$PLAN_CHAIN" --from-plan "${1:?--from-plan requires a planner artifact}" --execute --unattended "${@:2}"
    ;;
  --from-plan=*)
    from_plan="${1#--from-plan=}"
    shift
    exec "$PLAN_CHAIN" --from-plan "$from_plan" --execute --unattended "$@"
    ;;
esac

if [ "${1#-}" = "$1" ] && ! has_explicit_mode_flag "$@"; then
  exec "$RUNNER" --auto "$@"
fi

exec "$RUNNER" "$@"
