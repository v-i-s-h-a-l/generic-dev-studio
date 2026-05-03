#!/usr/bin/env bash
# run-apollo-network-reviewed-chain.sh — retired Apollo network chain launcher.
#
# Usage:
#   scripts/run-apollo-network-reviewed-chain.sh [--dry-run] [--foreground]
#
# The apollo-network-efficiency chain manifest was retired. Use:
#   scripts/studio-chain-reviewed.sh v2-transition --host codex --review-host claude-reviewer

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|--foreground) shift ;;
    -h|--help) usage ;;
    *)
      printf 'run-apollo-network-reviewed-chain: unknown flag %s\n' "$1" >&2
      usage
      ;;
  esac
done

printf 'run-apollo-network-reviewed-chain: apollo-network-efficiency manifest is retired\n' >&2
printf 'run-apollo-network-reviewed-chain: use %q %q --host codex --review-host claude-reviewer\n' "$SCRIPT_DIR/studio-chain-reviewed.sh" "v2-transition" >&2
exit 1
