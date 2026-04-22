#!/usr/bin/env bash
# write-event.sh — CLI wrapper over emit_event_keyed.
#
# Every mode pack that emits events shells out here instead of assembling the
# JSONL envelope inline. Keeps the envelope format + atomicity budget + dedupe
# key in one place (scripts/lib-ledger.sh) rather than sprinkled across 20+
# mode-pack prose examples.
#
# Usage:
#   scripts/write-event.sh --agent <a> --event <e> --task <t> --data <json> \
#                          [--mode <m>] [--instance <i>] [--idem-key <k>]
#
# Exit codes:
#   0  event appended (or logged when DRY_RUN=1)
#   2  malformed --data JSON or missing required flag
#   3  envelope > 4096 byte atomicity cap
#
# Env:
#   DRY_RUN=1   skip append; log to stderr instead

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

AGENT=""
EVENT=""
TASK=""
DATA='{}'
MODE=""
INSTANCE=""
IDEM=""

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)    AGENT="${2:?--agent requires a value}";    shift 2 ;;
    --event)    EVENT="${2:?--event requires a value}";    shift 2 ;;
    --task)     TASK="${2:-}";                             shift 2 ;;
    --data)     DATA="${2:-\{\}}";                         shift 2 ;;
    --mode)     MODE="${2:-}";                             shift 2 ;;
    --instance) INSTANCE="${2:-}";                         shift 2 ;;
    --idem-key) IDEM="${2:-}";                             shift 2 ;;
    -h|--help)  usage ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done

[ -z "$AGENT" ] && { printf 'write-event.sh: --agent is required\n' >&2; exit 2; }
[ -z "$EVENT" ] && { printf 'write-event.sh: --event is required\n' >&2; exit 2; }

# Validate --data via jq first (preferred; ships in pre-flight), else python3.
if command -v jq >/dev/null 2>&1; then
  if ! printf '%s' "$DATA" | jq empty >/dev/null 2>&1; then
    printf 'write-event.sh: --data is not valid JSON\n' >&2
    exit 2
  fi
elif command -v python3 >/dev/null 2>&1; then
  if ! python3 -c 'import sys, json; json.loads(sys.argv[1])' "$DATA" >/dev/null 2>&1; then
    printf 'write-event.sh: --data is not valid JSON\n' >&2
    exit 2
  fi
else
  printf 'write-event.sh: neither jq nor python3 available to validate --data\n' >&2
  exit 2
fi

# Expand optional flags via a safe-under-`set -u` pattern (`${arr[@]+...}`) —
# bash errors on `"${arr[@]}"` for an empty-unset array when nounset is on.
args=()
[ -n "$INSTANCE" ] && args+=("--instance-id" "$INSTANCE")
[ -n "$IDEM" ]     && args+=("--idem-key"    "$IDEM")

emit_event_keyed "$AGENT" "$MODE" "$EVENT" "$TASK" "$DATA" ${args[@]+"${args[@]}"}
rc=$?
exit "$rc"
