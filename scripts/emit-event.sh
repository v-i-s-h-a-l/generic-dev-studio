#!/usr/bin/env bash
# emit-event.sh — append a single event to today's studio event log.
#
# Thin wrapper around lib-ledger.sh's emit_event_keyed for non-agent emitters
# (cron jobs, install scripts, LaunchAgents) that don't have agent / mode /
# task context. Used by:
#   - scripts/update-recipes.sh         pr_review_ready
#   - scripts/install-skill-launchagent.sh  (future)
#
# Usage:
#   scripts/emit-event.sh <event-name> [k=v ...]
#
# Each k=v pair becomes a top-level data field. Values containing spaces
# should be quoted at the shell level.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || {
  printf 'emit-event: lib-ledger.sh not found\n' >&2; exit 2
}

EVENT="${1:?usage: emit-event.sh <event-name> [k=v ...]}"
shift

# Build a JSON object from the k=v args.
data='{}'
if command -v jq >/dev/null 2>&1; then
  for kv in "$@"; do
    case "$kv" in
      *=*)
        key="${kv%%=*}"
        val="${kv#*=}"
        data=$(printf '%s' "$data" | jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}')
        ;;
    esac
  done
else
  # Fallback: hand-roll a JSON object.
  parts=""
  for kv in "$@"; do
    case "$kv" in
      *=*)
        key="${kv%%=*}"
        val="${kv#*=}"
        # Naive escape — sufficient for the controlled inputs of internal callers.
        val=${val//\\/\\\\}
        val=${val//\"/\\\"}
        parts="$parts,\"$key\":\"$val\""
        ;;
    esac
  done
  data="{${parts#,}}"
fi

# emit_event_keyed agent mode event task data
emit_event_keyed studio external "$EVENT" "" "$data" >/dev/null 2>&1 || {
  # Fallback: write directly to today's event log so the call is never lost.
  local_event_dir="$HOME/.dev-studio/$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")/events"
  mkdir -p "$local_event_dir"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  date_only=${ts%%T*}
  printf '{"ts":"%s","agent":"studio","mode":"external","event":"%s","data":%s}\n' \
    "$ts" "$EVENT" "$data" >> "$local_event_dir/$date_only.jsonl"
}

exit 0
