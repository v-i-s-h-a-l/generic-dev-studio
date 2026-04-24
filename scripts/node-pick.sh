#!/usr/bin/env bash
# node-pick.sh — pick the least-loaded healthy node that advertises a role,
# or fall back to `local` if none qualify.
#
# Reads the machine-global registry (`~/.dev-studio/.runtime/nodes.json`),
# filters to enabled nodes whose `roles` include <role>, probes each via
# node-health.sh, and prints the id of the node with the lowest 1-minute
# load. Missing registry / unknown role / all nodes unreachable → prints
# `local` and exits 0. The fallback is the whole point: callers pipe the
# output straight into node-dispatch.sh without branching.
#
# Usage:
#   scripts/node-pick.sh <role>
#
# Output: a single line — either a node id from the registry, or `local`.
#
# Exit codes:
#   0   picked a node (or `local`)
#   2   bad args / registry parse error

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

ROLE="${1:?usage: node-pick.sh <role>}"

REGISTRY="$(resolve_runtime_global)/nodes.json"
if [ ! -r "$REGISTRY" ]; then
  echo "local"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }

# Candidate ids: enabled nodes that advertise <role>.
# Drop `.enabled == false` explicitly — jq's `//` treats false like null,
# so `(.enabled // true) == true` would incorrectly include disabled nodes.
CANDIDATES=$(jq -r --arg role "$ROLE" \
  '.nodes[]? | select(.enabled != false) | select(.roles? // [] | index($role)) | .id' \
  "$REGISTRY" 2>/dev/null) || CANDIDATES=""

if [ -z "$CANDIDATES" ]; then
  echo "local"
  exit 0
fi

# Probe each candidate; sort healthy rows by load ascending; take the
# first id. Health script's output format:
#   <id>\t<status>\t<load1>\t<host>
best=""
best_load=""
while IFS= read -r id; do
  [ -z "$id" ] && continue
  row=$("$SCRIPT_DIR/node-health.sh" "$id" 2>/dev/null | head -n 1)
  status=$(printf '%s' "$row" | awk -F'\t' '{print $2}')
  load=$(printf '%s' "$row" | awk -F'\t' '{print $3}')
  [ "$status" = "healthy" ] || continue
  # Lexicographic compare on zero-padded floats would be cleaner, but awk
  # handles numeric compare correctly and we already have it in hand.
  if [ -z "$best_load" ] || awk -v a="$load" -v b="$best_load" 'BEGIN{exit !(a<b)}'; then
    best="$id"
    best_load="$load"
  fi
done <<EOF
$CANDIDATES
EOF

if [ -z "$best" ]; then
  echo "local"
  exit 0
fi

echo "$best"
