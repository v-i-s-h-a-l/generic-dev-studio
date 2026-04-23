#!/usr/bin/env bash
# waive-lift.sh <gate>
#
# Removes the structured review-waive record at
# ~/.dev-studio/<project>/state/waives/<gate>.yaml for the current project,
# reporting the accumulator so the user knows how many merges skipped review
# during the pause.
#
# Exit codes:
#   0  lifted (or already absent — idempotent)
#   2  arg parse / resolution error

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

GATE="${1:-}"
if [ -z "$GATE" ]; then
  printf 'usage: waive-lift.sh <gate>\n' >&2
  exit 2
fi

PROJECT=$(resolve_project 2>/dev/null) || { printf 'waive-lift.sh: no project resolved\n' >&2; exit 2; }
F=$(resolve_waive_file_for "$PROJECT" "$GATE")

if [ ! -f "$F" ]; then
  printf 'waive-lift.sh: no active waive for gate=%s (project=%s)\n' "$GATE" "$PROJECT"
  exit 0
fi

count=0
if command -v yq >/dev/null 2>&1; then
  count=$(yq -r '.accumulated_count // 0' "$F" 2>/dev/null || echo 0)
fi

rm -f "$F" || { printf 'waive-lift.sh: failed to remove %s\n' "$F" >&2; exit 2; }
printf 'waive lifted: gate=%s project=%s · %s tasks merged without review during the pause\n' \
  "$GATE" "$PROJECT" "$count"
