#!/usr/bin/env bash
# manager-work-chain.sh — repo-side front door for work-chain discovery/start/resume.
#
# This stays thin on purpose: /dev-studio manager shapes intent, then delegates
# the actual execution and resumable-run machinery to studio-chain-runner.sh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
RUNNER="$SCRIPT_DIR/studio-chain-runner.sh"

has_explicit_mode_flag() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --auto|--auto=*|--discover|--list|--resume|--resume=*|--explain-next|--explain-next=*)
        return 0
        ;;
    esac
  done
  return 1
}

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/manager-work-chain.sh [<manifest|chain-name>] [runner-flags...]

When no chain is named, this defaults to discovery so the manager front door
can suggest runnable chains and resumable runs. Named chains default to
unattended supervisor selection through scripts/studio-chain-runner.sh --auto.
Use --discover [<manifest|chain-name>] for filtered, non-mutating discovery.
All runner flags are passed through to scripts/studio-chain-runner.sh.

Preferred user-facing entrypoint:
  /dev-studio manager work-chain [<manifest|chain-name>] [runner-flags...]
EOF
  exit 2
}

if [ "$#" -eq 0 ]; then
  exec "$RUNNER" --discover
fi

case "$1" in
  -h|--help) usage ;;
esac

if [ "${1#-}" = "$1" ] && ! has_explicit_mode_flag "$@"; then
  exec "$RUNNER" --auto "$@"
fi

exec "$RUNNER" "$@"
