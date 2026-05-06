#!/usr/bin/env bash
# manager-work-chain.sh — repo-side front door for work-chain discovery/start/resume.
#
# This stays thin on purpose: the manager shapes intent, then delegates the
# actual execution and resumable-run machinery to studio-chain-runner.sh.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
RUNNER="$SCRIPT_DIR/studio-chain-runner.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/manager-work-chain.sh [<manifest|chain-name>] [runner-flags...]

When no chain is named, this defaults to discovery so the manager front door
can suggest runnable manifests and resumable runs. All runner flags are passed
through to scripts/studio-chain-runner.sh.
EOF
  exit 2
}

if [ "$#" -eq 0 ]; then
  exec "$RUNNER" --discover
fi

case "$1" in
  -h|--help) usage ;;
esac

exec "$RUNNER" "$@"
