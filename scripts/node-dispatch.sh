#!/usr/bin/env bash
# node-dispatch.sh — run a command on a registered worker node, or locally.
#
# Resolves <node-id> against the machine-global node registry
# (`~/.dev-studio/.runtime/nodes.json`), runs a 10-second SSH health check
# to confirm reachability, then streams the command over SSH and exits
# with the remote exit code. An unreachable node (or disabled entry, or
# missing registry) silently falls back to local execution — this is a
# hard requirement: no manual intervention when a remote node drops.
#
# The 10-second bound lives on the health check, not on the command
# itself. A 40-minute xcodebuild on a reachable node must not get killed
# because the caller set a short timeout; the only cost the caller pays
# for remote dispatch is the reachability probe.
#
# Usage:
#   scripts/node-dispatch.sh <node-id> <command> [args...]
#   scripts/node-dispatch.sh local <command> [args...]    # explicit local
#
# Exit codes:
#   *   propagated from the remote (or local) command
#   2   bad args / unknown node / registry parse error
#
# Env:
#   NODE_DISPATCH_DEBUG=1   log the route decision (remote vs fallback) to stderr

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-dispatch-registry.sh
. "$SCRIPT_DIR/lib-dispatch-registry.sh"

NODE_ID="${1:?usage: node-dispatch.sh <node-id> <command> [args...]}"
shift
[ $# -gt 0 ] || { printf 'error: no command given\n' >&2; exit 2; }

log_route() {
  [ "${NODE_DISPATCH_DEBUG:-0}" = "1" ] || return 0
  printf 'node-dispatch: %s\n' "$*" >&2
}

exec_local() {
  log_route "running locally ($*)"
  exec "$@"
}

if [ "$NODE_ID" = "local" ]; then
  exec_local "$@"
fi

REGISTRY="$(resolve_runtime_global)/nodes.json"
if [ ! -r "$REGISTRY" ]; then
  log_route "registry missing at $REGISTRY — falling back to local"
  exec_local "$@"
fi

command -v jq >/dev/null 2>&1 || { printf 'error: jq required to read %s\n' "$REGISTRY" >&2; exit 2; }

# #215 — self-node short-circuit. A registered entry whose machine_id matches
# this machine's id is *this* machine; SSH would loop back through the network
# stack for no benefit (and for a laptop without sshd enabled, would fail).
# Order matters: precedes the host/user fetch so a self-entry without an
# externally-reachable host still works.
if node_is_self "$NODE_ID"; then
  log_route "node $NODE_ID is self — running locally"
  exec_local "$@"
fi

# Extract host/user/enabled for this node. jq's -r -e returns exit 1 iff the
# filter yields null — lets us detect "not in registry" without a separate
# probe. Trailing `// empty` on the sub-fields guards against partial entries.
NODE_JSON=$(jq -r -e --arg id "$NODE_ID" \
  '.nodes[]? | select(.id == $id)' "$REGISTRY" 2>/dev/null) || {
  printf 'error: unknown node-id: %s\n' "$NODE_ID" >&2
  exit 2
}

# `.enabled // true` is wrong: jq's `//` treats `false` like null, so
# `enabled: false` would survive as `true`. Compare against literal false.
ENABLED=$(printf '%s' "$NODE_JSON" | jq -r 'if .enabled == false then "false" else "true" end')
if [ "$ENABLED" != "true" ]; then
  log_route "node $NODE_ID is disabled — falling back to local"
  exec_local "$@"
fi

HOST=$(printf '%s' "$NODE_JSON" | jq -r '.host // empty')
USER_=$(printf '%s' "$NODE_JSON" | jq -r '.user // empty')
if [ -z "$HOST" ] || [ -z "$USER_" ]; then
  printf 'error: node %s missing host/user in %s\n' "$NODE_ID" "$REGISTRY" >&2
  exit 2
fi

# BatchMode=yes: no password prompts — if key auth fails, we fall back to
# local rather than stalling the pipeline. accept-new: first-connect TOFU
# without dropping to an interactive known_hosts prompt.
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=2
  -o StrictHostKeyChecking=accept-new
)

# Health probe: cheap `true` over SSH. ConnectTimeout=10 on its own
# bounds the TCP connect + handshake; `gtimeout` (coreutils on macOS)
# additionally caps the full round trip when available. If neither the
# SSH handshake nor the remote exec returns, we treat the node as
# unreachable regardless of why.
TIMEOUT_BIN=""
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout 10"
command -v timeout  >/dev/null 2>&1 && [ -z "$TIMEOUT_BIN" ] && TIMEOUT_BIN="timeout 10"
if ! $TIMEOUT_BIN ssh "${SSH_OPTS[@]}" "${USER_}@${HOST}" true >/dev/null 2>&1; then
  log_route "node $NODE_ID ($HOST) unreachable — falling back to local"
  exec_local "$@"
fi

log_route "dispatching to $NODE_ID ($HOST)"

# Remote invocation: quote each arg so multi-word tokens (e.g.
# `git commit -m "long msg with spaces"`) survive the shell round trip.
# printf %q is bash-builtin, no external fork.
REMOTE_CMD=""
for arg in "$@"; do
  REMOTE_CMD+=$(printf '%q ' "$arg")
done

# #269 — dispatch UUID + remote log persistence. Every remote run gets a
# UUID; the worker tees stdout/stderr to ~/.dev-studio/.runtime/logs/<uuid>.log
# and writes <uuid>.exit (single-line exit code) on completion. Together
# they let #147-B (registry) and #147-C (reconnect-and-harvest) recover
# the result of a build whose dispatching laptop disappeared mid-run.
#
# UUID generation: prefer uuidgen, fall back to /proc/sys (linux) or a
# hex-from-urandom dance (macOS without util-linux). Lowercased for
# filesystem consistency.
if command -v uuidgen >/dev/null 2>&1; then
  DISPATCH_UUID=$(uuidgen | tr 'A-Z' 'a-z')
elif [ -r /proc/sys/kernel/random/uuid ]; then
  DISPATCH_UUID=$(cat /proc/sys/kernel/random/uuid)
else
  DISPATCH_UUID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
    sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
fi
printf 'node-dispatch: uuid=%s\n' "$DISPATCH_UUID" >&2

# #270 — laptop-side dispatch registry. Callers (the build/test gates) set
# STUDIO_DISPATCH_TASK_ID + STUDIO_DISPATCH_UUID_FILE to opt in. The sidecar
# file lets the caller capture the UUID across the upcoming `exec ssh` (which
# replaces this process — stderr scraping by the parent is unreliable for
# dispatches whose stderr is teed into a build log). Both writes are
# best-effort; failures here must not abort the dispatch.
if [ -n "${STUDIO_DISPATCH_UUID_FILE:-}" ]; then
  printf '%s\n' "$DISPATCH_UUID" > "$STUDIO_DISPATCH_UUID_FILE" 2>/dev/null || true
fi
if [ -n "${STUDIO_DISPATCH_TASK_ID:-}" ]; then
  dispatch_registry_record "$DISPATCH_UUID" "$NODE_ID" "$STUDIO_DISPATCH_TASK_ID" \
    2>/dev/null || true
fi

# Wrapper executed on the worker. Single-quoted heredoc — no interpolation
# happens on the laptop side; UUID and command travel as positional args.
# The runner is fully detached (nohup + redirected stdio + disown) so it
# survives the laptop's ssh client dying. tail -F streams the log back
# during normal operation; on disconnect tail dies but the runner keeps
# writing to the log and the .exit file.
#
# REVIEW R3 exception: LOG_DIR is the only literal $HOME/.dev-studio/.runtime
# path in this repo outside lib-paths.sh, intentionally. The wrapper runs on
# a remote worker that does not source lib-paths.sh; the path mirrors
# `resolve_runtime_global()` on the remote — keep them in sync if either
# side moves.
REMOTE_WRAPPER=$(cat <<'REMOTE_EOF'
set -u
UUID="$1"
CMD="$2"
LOG_DIR="$HOME/.dev-studio/.runtime/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$UUID.log"
EXIT_FILE="$LOG_DIR/$UUID.exit"

# Atomic exit-file write via mv so a reader (#147-C) never sees a partial
# file. CMD already arrives printf-%q-quoted; bash -c reconstructs argv.
nohup bash -c '
  bash -c "$1"
  rc=$?
  printf "%s\n" "$rc" > "$2.tmp" && mv "$2.tmp" "$2"
  exit $rc
' _ "$CMD" "$EXIT_FILE" >"$LOG" 2>&1 </dev/null &
RUNNER=$!
disown 2>/dev/null || true

tail -n +1 -F "$LOG" 2>/dev/null &
TAIL=$!

# Poll runner liveness: bash `wait` would return immediately on a disowned
# pid. Sleep granularity matches normal build feedback latency.
while kill -0 "$RUNNER" 2>/dev/null; do sleep 1; done
sleep 0.3
kill "$TAIL" 2>/dev/null || true
wait "$TAIL" 2>/dev/null || true

if [ -r "$EXIT_FILE" ]; then
  exit "$(cat "$EXIT_FILE")"
fi
exit 1
REMOTE_EOF
)

exec ssh "${SSH_OPTS[@]}" "${USER_}@${HOST}" -- bash -s -- \
  "$DISPATCH_UUID" "$REMOTE_CMD" <<<"$REMOTE_WRAPPER"
