#!/usr/bin/env bash
# node-health.sh — check whether a registered worker node is reachable
# and report its 1-minute load average.
#
# With an id: probe just that node. Without: probe every enabled node.
# Output is one line per node, parseable by node-pick.sh:
#
#   <node-id>\t<status>\t<load1>\t<host>
#
# Status is one of: healthy | unreachable | disabled | unknown.
# load1 is the 1-minute load average (float), or `-` if unreachable.
#
# Exit codes:
#   0   at least one node is healthy (or the requested node is healthy)
#   1   no node healthy
#   2   bad args / registry parse error
#
# Usage:
#   scripts/node-health.sh               # all enabled nodes
#   scripts/node-health.sh <node-id>     # one node

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

TARGET_ID="${1:-}"

REGISTRY="$(resolve_runtime_global)/nodes.json"
if [ ! -r "$REGISTRY" ]; then
  [ -n "$TARGET_ID" ] && printf '%s\tunknown\t-\t-\n' "$TARGET_ID"
  exit 1
fi

command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }

# Pull the nodes we care about as tab-separated rows for easy read. jq's
# @tsv escapes newlines / tabs inside fields — keeps the read loop robust
# even if someone mis-configures a host string. Empty filter result is an
# empty stream, not an error.
# `.enabled // true` is wrong here — jq's `//` treats `false` like null,
# so an explicitly-disabled node would appear enabled. Use an if-chain.
ENABLED_EXPR='(if .enabled == false then "false" else "true" end)'
ROW_EXPR=".nodes[]? | [.id, (.host // \"-\"), (.user // \"-\"), ${ENABLED_EXPR}] | @tsv"

if [ -n "$TARGET_ID" ]; then
  ROWS=$(jq -r --arg id "$TARGET_ID" \
    "(.nodes[]? | select(.id == \$id) | [.id, (.host // \"-\"), (.user // \"-\"), ${ENABLED_EXPR}] | @tsv)" \
    "$REGISTRY" 2>/dev/null) || ROWS=""
  if [ -z "$ROWS" ]; then
    printf '%s\tunknown\t-\t-\n' "$TARGET_ID"
    exit 1
  fi
else
  ROWS=$(jq -r "$ROW_EXPR" "$REGISTRY" 2>/dev/null) || ROWS=""
fi

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
)

# `gtimeout` ships via coreutils on macOS; `timeout` is GNU-only on Linux.
# Missing on a vanilla Mac is common, so fall through gracefully — SSH's
# own ConnectTimeout still bounds the dominant failure mode (TCP hang).
TIMEOUT_BIN=""
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout 10"
command -v timeout  >/dev/null 2>&1 && [ -z "$TIMEOUT_BIN" ] && TIMEOUT_BIN="timeout 10"

any_healthy=0

while IFS=$'\t' read -r id host user enabled; do
  [ -z "$id" ] && continue
  if [ "$enabled" != "true" ]; then
    printf '%s\tdisabled\t-\t%s\n' "$id" "$host"
    continue
  fi
  # One call to fetch load + confirm reachability. `uptime` output shape:
  #   "... load averages: 1.23 1.45 1.67"  (BSD)
  #   "... load average: 1.23, 1.45, 1.67" (Linux)
  # We grab the first float after "load", matching both.
  output=$($TIMEOUT_BIN ssh "${SSH_OPTS[@]}" "${user}@${host}" uptime 2>/dev/null) || {
    printf '%s\tunreachable\t-\t%s\n' "$id" "$host"
    continue
  }
  load1=$(printf '%s' "$output" | sed -n 's/.*load[^:]*:[[:space:]]*\([0-9][0-9]*\(\.[0-9]*\)\{0,1\}\).*/\1/p')
  [ -z "$load1" ] && load1="0.00"
  printf '%s\thealthy\t%s\t%s\n' "$id" "$load1" "$host"
  any_healthy=1
done <<EOF
$ROWS
EOF

[ "$any_healthy" = "1" ] && exit 0
exit 1
