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
#   scripts/node-pick.sh [--requires-secret-scope <a>[,<b>...]] <role>
#
# `--requires-secret-scope` (#284) restricts candidates to nodes whose
# `secret_scopes` field includes every requested scope. Nodes with a missing
# or empty `secret_scopes` advertise no scopes and are filtered out when the
# flag is passed. With no flag, the field is ignored (existing behavior).
# Locks D2 from #217 — TF/AS dispatchers ask for `asc,slack`; only the laptop
# advertises both, so mini is structurally excluded.
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
#     | fallback:secret-scope | forced-local | pinned
#   Callers (build/test gates) pre-create the file, read it after the
#   pick, and tag `studio.dispatch.reason` on their gate events. Keeping
#   stdout = node-id preserves the long-standing caller contract.
#
# Escape hatches (#820 item 6):
#   STUDIO_DISPATCH_FORCE_LOCAL=1 — bypass node selection; return `local`
#     immediately. Use when the user wants laptop-only execution without
#     editing nodes.json. Race-safe vs other Achilles instances.
#   STUDIO_DISPATCH_PIN=<node-id> — explicit pin. The named node must
#     exist + be enabled + carry the requested role/scopes. Mismatch is a
#     hard error (exit 2), not a silent fallback — the user's intent stays
#     visible.
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

REQUIRED_SCOPES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --requires-secret-scope) REQUIRED_SCOPES="${2:?--requires-secret-scope requires <a,b,...>}"; shift 2 ;;
    --) shift; break ;;
    -*) printf 'node-pick: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
  esac
done

ROLE="${1:?usage: node-pick.sh [--requires-secret-scope a,b] <role>}"

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

# #820 item 6: documented escape hatches.
#
# STUDIO_DISPATCH_FORCE_LOCAL=1 — bypass node selection entirely; return
# `local` immediately with reason `forced-local`. Use when the user wants
# laptop-only execution without editing nodes.json (which races other
# Achilles instances).
case "${STUDIO_DISPATCH_FORCE_LOCAL:-0}" in
  1|true|TRUE|yes|YES)
    _record_reason "forced-local"
    _emit_fallback "forced-local"
    echo "local"
    exit 0
    ;;
esac

# STUDIO_DISPATCH_PIN=<node-id> — explicit pin. The named node must exist
# in the registry, be enabled, and carry the requested role (and any
# requested secret scopes). On any mismatch this is a HARD ERROR — pinning
# a broken node should not silently fall back, otherwise the user's
# operational intent is hidden. Use STUDIO_DISPATCH_FORCE_LOCAL=1 instead
# when the goal is "skip remote dispatch."
if [ -n "${STUDIO_DISPATCH_PIN:-}" ]; then
  if [ ! -r "$REGISTRY" ]; then
    printf 'node-pick: STUDIO_DISPATCH_PIN=%s but registry %s is unreadable\n' "$STUDIO_DISPATCH_PIN" "$REGISTRY" >&2
    exit 2
  fi
  command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }
  pinned=$(jq -r --arg id "$STUDIO_DISPATCH_PIN" --arg role "$ROLE" --arg req "$REQUIRED_SCOPES" '
    .nodes[]?
    | select(.id == $id)
    | select(.enabled != false)
    | select(.roles? // [] | index($role))
    | (if $req == "" then .id else
        ($req | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $r
        | select(($r - (.secret_scopes // [])) == [])
        | .id
       end)
  ' "$REGISTRY" 2>/dev/null | head -1)
  if [ -z "$pinned" ]; then
    printf 'node-pick: STUDIO_DISPATCH_PIN=%s does not match any enabled node with role=%s' \
      "$STUDIO_DISPATCH_PIN" "$ROLE" >&2
    [ -n "$REQUIRED_SCOPES" ] && printf ' scopes=%s' "$REQUIRED_SCOPES" >&2
    printf ' (use STUDIO_DISPATCH_FORCE_LOCAL=1 for local-only)\n' >&2
    exit 2
  fi
  _record_reason "pinned"
  printf '%s\n' "$pinned"
  exit 0
fi

if [ ! -r "$REGISTRY" ]; then
  _record_reason "fallback:unreachable"
  _emit_fallback "fallback:unreachable"
  echo "local"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }

# Drop `.enabled == false` explicitly — jq's `//` treats false like null,
# so `(.enabled // true) == true` would incorrectly include disabled nodes.
# Secret-scope filter (#284): when REQUIRED_SCOPES is set, every requested
# scope must appear in the node's `secret_scopes` (missing field = empty).
# `($req - $have) == []` is the "$have ⊇ $req" check in jq idiom.
if [ -n "$REQUIRED_SCOPES" ]; then
  CANDIDATES=$(jq -r --arg role "$ROLE" --arg req "$REQUIRED_SCOPES" \
    '($req | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $r
     | .nodes[]?
     | select(.enabled != false)
     | select(.roles? // [] | index($role))
     | select(($r - (.secret_scopes // [])) == [])
     | .id' \
    "$REGISTRY" 2>/dev/null) || CANDIDATES=""
else
  CANDIDATES=$(jq -r --arg role "$ROLE" \
    '.nodes[]? | select(.enabled != false) | select(.roles? // [] | index($role)) | .id' \
    "$REGISTRY" 2>/dev/null) || CANDIDATES=""
fi

if [ -z "$CANDIDATES" ]; then
  # Distinguish "no node has this role" from "all role-bearing nodes are
  # disabled" from "no role-bearing node advertises the required scopes" —
  # each has a different operational meaning and a different fix.
  ANY_ROLE=$(jq -r --arg role "$ROLE" \
    '.nodes[]? | select(.roles? // [] | index($role)) | .id' \
    "$REGISTRY" 2>/dev/null) || ANY_ROLE=""
  ENABLED_ROLE=$(jq -r --arg role "$ROLE" \
    '.nodes[]? | select(.enabled != false) | select(.roles? // [] | index($role)) | .id' \
    "$REGISTRY" 2>/dev/null) || ENABLED_ROLE=""
  if [ -z "$ANY_ROLE" ]; then
    reason="fallback:no-role"
  elif [ -z "$ENABLED_ROLE" ]; then
    reason="fallback:disabled"
  else
    # Role-bearing + enabled candidates exist but none carry the requested
    # secret scopes. Distinct signal — points at the registry's secret_scopes
    # field, not at health/role/enabled config.
    reason="fallback:secret-scope"
  fi
  _record_reason "$reason"
  _emit_fallback "$reason"
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
  # `moved` is dispatchable (#146) — the worker is reachable; the drift
  # signal is observability via `node_machine_id_drift`, not a block.
  case "$status" in healthy|moved) ;; *) continue ;; esac
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
