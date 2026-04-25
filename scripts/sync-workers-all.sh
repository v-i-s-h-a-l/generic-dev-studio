#!/usr/bin/env bash
# sync-workers-all.sh — fan-out wrapper: iterate every enabled worker in
# nodes.json, run sync-worker.sh against each, aggregate results.
#
# Designed to be invoked by the scheduled launchd agent (see
# schedule-worker-sync.sh) but also fine to run manually.
#
# Usage
#   scripts/sync-workers-all.sh
#   scripts/sync-workers-all.sh --dry-run
#
# Exit codes
#   0  every worker is in-sync (or was after applying)
#   1  one or more workers had unrecoverable errors
#   2  manifest / registry parse error

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

REGISTRY="$(resolve_runtime_global)/nodes.json"
[ -r "$REGISTRY" ] || { printf 'error: node registry missing at %s\n' "$REGISTRY" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }

# Fetch every enabled worker id. Disabled entries are silently skipped —
# that's the user's signal to "pause this worker."
WORKER_IDS=$(jq -r '.nodes[]? | select(.enabled != false) | .id' "$REGISTRY" 2>/dev/null)

if [ -z "$WORKER_IDS" ]; then
  printf 'sync-workers-all: no enabled workers in registry — nothing to do\n'
  exit 0
fi

total=0; ok=0; skip=0; fail=0

while IFS= read -r id; do
  [ -z "$id" ] && continue
  total=$((total + 1))
  printf '\n=== %s ===\n' "$id"
  if [ "$DRY_RUN" = "1" ]; then
    "$SCRIPT_DIR/sync-worker.sh" "$id" --dry-run
  else
    "$SCRIPT_DIR/sync-worker.sh" "$id"
  fi
  case $? in
    0) ok=$((ok + 1)) ;;
    1) skip=$((skip + 1)) ;;   # unreachable / disabled — not a hard fail
    *) fail=$((fail + 1)) ;;
  esac
done <<EOF
$WORKER_IDS
EOF

printf '\nsync-workers-all: total=%d ok=%d skipped=%d failed=%d\n' \
  "$total" "$ok" "$skip" "$fail"
[ "$fail" -gt 0 ] && exit 1
exit 0
