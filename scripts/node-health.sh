#!/usr/bin/env bash
# node-health.sh — check whether a registered worker node is reachable
# and report its 1-minute load average.
#
# With an id: probe just that node. Without: probe every enabled node.
# Output is one line per node, parseable by node-pick.sh:
#
#   <node-id>\t<status>\t<load1>\t<host>
#
# Status is one of: healthy | moved | unreachable | disabled | unknown.
#   - healthy:     reachable AND machine_id matches the registry (or no
#                  machine_id recorded → comparison skipped).
#   - moved:       reachable BUT remote machine_id differs from the
#                  registry's recorded value (#146). Hardware was replaced
#                  / reinstalled / id was rebound to a different box. Still
#                  dispatchable — node-pick treats `moved` as eligible —
#                  but a `node_machine_id_drift` event fires so the user
#                  can investigate. Re-register via `configure.sh worker
#                  add` to clear the drift.
#   - unreachable: probe failed (ssh / uptime non-zero).
#   - disabled:    `enabled: false` in the registry.
#   - unknown:     id not in the registry.
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
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

TARGET_ID="${1:-}"

# _emit_unreachable <id> <probe> <error> — discriminating event for R14
# (issue #137). Best-effort; never blocks the probe loop. Caller dedups
# by node id at the analytics layer if needed.
_emit_unreachable() {
  local id="$1" probe="$2" err="$3"
  command -v emit_event_keyed >/dev/null 2>&1 || return 0
  err=${err:0:200}
  err=${err//\\/\\\\}
  err=${err//\"/\\\"}
  local data
  data=$(printf '{"studio.dispatch.node":"%s","studio.dispatch.probe":"%s","studio.dispatch.error":"%s"}' \
    "$id" "$probe" "$err")
  emit_event_keyed studio dispatch node_unreachable "" "$data" >/dev/null 2>&1 || true
}

# _emit_machine_id_drift <id> <expected> <observed> — emit when the
# remote's machine-id contradicts the registry (#146). Truncate ids in
# data payload to keep the line under the 4096-byte atomicity cap; full
# values are short UUIDs anyway.
_emit_machine_id_drift() {
  local id="$1" expected="$2" observed="$3"
  command -v emit_event_keyed >/dev/null 2>&1 || return 0
  local data
  data=$(printf '{"studio.dispatch.node":"%s","studio.dispatch.expected_machine_id":"%s","studio.dispatch.observed_machine_id":"%s"}' \
    "$id" "${expected:0:64}" "${observed:0:64}")
  emit_event_keyed studio dispatch node_machine_id_drift "" "$data" >/dev/null 2>&1 || true
}

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
# 5th field: registry's machine_id (empty when unset — back-compat, skips
# the drift check for legacy entries that pre-date #146).
ROW_EXPR=".nodes[]? | [.id, (.host // \"-\"), (.user // \"-\"), ${ENABLED_EXPR}, (.machine_id // \"\")] | @tsv"

if [ -n "$TARGET_ID" ]; then
  ROWS=$(jq -r --arg id "$TARGET_ID" \
    "(.nodes[]? | select(.id == \$id) | [.id, (.host // \"-\"), (.user // \"-\"), ${ENABLED_EXPR}, (.machine_id // \"\")] | @tsv)" \
    "$REGISTRY" 2>/dev/null) || ROWS=""
  if [ -z "$ROWS" ]; then
    printf '%s\tunknown\t-\t-\n' "$TARGET_ID"
    exit 1
  fi
else
  ROWS=$(jq -r "$ROW_EXPR" "$REGISTRY" 2>/dev/null) || ROWS=""
fi

SSH_OPTS=(
  -n                                # no stdin — otherwise ssh reads the loop's heredoc and starves subsequent iterations (#215)
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ConnectionAttempts=1
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
  -o StrictHostKeyChecking=accept-new
)

NODE_HEALTH_TIMEOUT_S="${STUDIO_NODE_HEALTH_TIMEOUT_S:-10}"
case "$NODE_HEALTH_TIMEOUT_S" in ''|*[!0-9]*|0) NODE_HEALTH_TIMEOUT_S=10 ;; esac

node_health_run_with_timeout() {
  local timeout_s="$1"
  shift
  local out pid started elapsed rc
  out=$(mktemp -t node-health-probe.XXXXXX) || return 125
  if (
    set +e
    set -m
    "$@" >"$out" 2>&1 &
    pid=$!
    started=$(date -u +%s)
    rc=""
    while kill -0 "$pid" 2>/dev/null; do
      elapsed=$(( $(date -u +%s) - started ))
      if [ "$elapsed" -ge "$timeout_s" ]; then
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rc=124
        break
      fi
      sleep 1
    done
    if [ -z "$rc" ]; then
      wait "$pid"
      rc=$?
    fi
    exit "$rc"
  ) 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  cat "$out"
  rm -f "$out"
  return "$rc"
}

any_healthy=0

while IFS=$'\t' read -r id host user enabled expected_mid; do
  [ -z "$id" ] && continue
  if [ "$enabled" != "true" ]; then
    printf '%s\tdisabled\t-\t%s\n' "$id" "$host"
    continue
  fi
  # `uptime` output shape:
  #   "... load averages: 1.23 1.45 1.67"  (BSD)
  #   "... load average: 1.23, 1.45, 1.67" (Linux)
  # First float after "load" matches both.
  #
  # #215 — self-entry skips SSH and reads local uptime. Without this a laptop
  # that registers itself (so a peer mini can still see laptop's load) would
  # show `unreachable` whenever sshd is disabled at home, even though the
  # local copy of node-pick wants to dispatch work to itself.
  #
  # #146 — combined probe pulls uptime + remote machine-id in one SSH so
  # the drift check costs nothing extra. The marker (`###MID###`) is an
  # ASCII delimiter that uptime output cannot contain. cat is best-effort
  # — a worker without `~/.dev-studio/.runtime/machine-id` (pre-Phase-2.5)
  # returns empty after the marker; we treat that as "drift check skipped"
  # rather than as a probe failure.
  observed_mid=""
  if node_is_self "$id"; then
    if ! output=$(uptime 2>&1); then
      _emit_unreachable "$id" "uptime" "$output"
      printf '%s\tunreachable\t-\t%s\n' "$id" "$host"
      continue
    fi
    observed_mid=$(cat "$(resolve_runtime_global)/machine-id" 2>/dev/null | tr -d '[:space:]')
  else
    if ! output=$(node_health_run_with_timeout "$NODE_HEALTH_TIMEOUT_S" ssh "${SSH_OPTS[@]}" "${user}@${host}" \
        'uptime; printf "###MID###\n"; cat ~/.dev-studio/.runtime/machine-id 2>/dev/null' 2>&1); then
      _emit_unreachable "$id" "ssh" "$output"
      printf '%s\tunreachable\t-\t%s\n' "$id" "$host"
      continue
    fi
    observed_mid=$(printf '%s' "$output" | awk 'f{print; exit} /^###MID###$/{f=1}' | tr -d '[:space:]')
    output=$(printf '%s' "$output" | awk '/^###MID###$/{exit} {print}')
  fi
  load1=$(printf '%s' "$output" | sed -n 's/.*load[^:]*:[[:space:]]*\([0-9][0-9]*\(\.[0-9]*\)\{0,1\}\).*/\1/p')
  [ -z "$load1" ] && load1="0.00"
  # Drift check fires only when both sides know a machine-id. A registry
  # entry without machine_id (pre-#146) skips silently — re-register via
  # `configure.sh worker add` to opt in.
  status="healthy"
  if [ -n "$expected_mid" ] && [ -n "$observed_mid" ] && [ "$expected_mid" != "$observed_mid" ]; then
    _emit_machine_id_drift "$id" "$expected_mid" "$observed_mid"
    status="moved"
  fi
  printf '%s\t%s\t%s\t%s\n' "$id" "$status" "$load1" "$host"
  any_healthy=1
done <<EOF
$ROWS
EOF

[ "$any_healthy" = "1" ] && exit 0
exit 1
