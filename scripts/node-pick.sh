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
#
# Side channel:
#   STUDIO_DISPATCH_REASON_FILE — if set to a writable path, node-pick
#   writes a single line with the dispatch reason for the caller to fold
#   into its event payloads. One of:
#     healthy | fallback:unreachable | fallback:no-role | fallback:disabled
#   Callers (build/test gates) pre-create the file, read it after the
#   pick, and tag `studio.dispatch.reason` on their gate events. Keeping
#   stdout = node-id preserves the long-standing caller contract.
#
# R14: every fallback path emits `node_fallback` so analytics can tell
# "ran locally because we wanted to" from "fell back because the mini was
# down" — see issue #137 + REVIEW.md R14.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

ROLE="${1:?usage: node-pick.sh <role>}"

# _record_reason <reason> — write to side-channel file (best-effort).
_record_reason() {
  [ -n "${STUDIO_DISPATCH_REASON_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$STUDIO_DISPATCH_REASON_FILE" 2>/dev/null || true
}

# _emit_fallback <reason> — discriminating event for R14. Reason matches
# the gate-event enum so dashboards can join on one field.
_emit_fallback() {
  local reason="$1"
  command -v emit_event_keyed >/dev/null 2>&1 || return 0
  local data
  data=$(printf '{"studio.dispatch.requested_node":"","studio.dispatch.resolved_node":"local","studio.dispatch.role":"%s","studio.dispatch.reason":"%s"}' \
    "$ROLE" "$reason")
  emit_event_keyed studio dispatch node_fallback "" "$data" >/dev/null 2>&1 || true
}

REGISTRY="$(resolve_runtime_global)/nodes.json"
if [ ! -r "$REGISTRY" ]; then
  _record_reason "fallback:unreachable"
  _emit_fallback "fallback:unreachable"
  echo "local"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }

# Drop `.enabled == false` explicitly — jq's `//` treats false like null,
# so `(.enabled // true) == true` would incorrectly include disabled nodes.
CANDIDATES=$(jq -r --arg role "$ROLE" \
  '.nodes[]? | select(.enabled != false) | select(.roles? // [] | index($role)) | .id' \
  "$REGISTRY" 2>/dev/null) || CANDIDATES=""

if [ -z "$CANDIDATES" ]; then
  # Distinguish "no node has this role" from "all role-bearing nodes are
  # disabled" — the two have different operational meanings (config gap
  # vs deliberate disable) and different fixes.
  ANY_ROLE=$(jq -r --arg role "$ROLE" \
    '.nodes[]? | select(.roles? // [] | index($role)) | .id' \
    "$REGISTRY" 2>/dev/null) || ANY_ROLE=""
  if [ -z "$ANY_ROLE" ]; then
    _record_reason "fallback:no-role"
    _emit_fallback "fallback:no-role"
  else
    _record_reason "fallback:disabled"
    _emit_fallback "fallback:disabled"
  fi
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
  _record_reason "fallback:unreachable"
  _emit_fallback "fallback:unreachable"
  echo "local"
  exit 0
fi

_record_reason "healthy"
echo "$best"
