#!/usr/bin/env bash
# lib-dispatch-harvest.sh — reconnect-and-harvest of a prior remote dispatch (#271).
#
# When a gate's prior dispatch's laptop session died but the worker continued,
# `~/.dev-studio/.runtime/logs/<uuid>.exit` lands on the worker once the run
# finishes. Before re-running on retry, the gate calls into this lib to:
#
#   1. Find the most recent in-flight registry entry for {task_id, node}.
#   2. Probe the worker for `<uuid>.exit`.
#   3. If present  → rsync log + exit, return harvested exit code.
#   4. If only log → tail-stream and wait until exit lands, capped at
#      STUDIO_HARVEST_TIMEOUT_S (default 30 min, matches xcodebuild lock cap).
#   5. Caller marks the registry entry harvested + emits dispatch_harvested.
#
# The harvest is best-effort. Any failure on the probe path returns non-zero
# so the caller falls back to the normal retry — the gate must never wedge
# waiting for harvest to succeed.
#
# Path scope (R4 carve-out, same as lib-dispatch-registry.sh): the dispatch
# UUID + worker logs are machine-global; this lib reads `nodes.json` and
# `dispatch-registry/` under the global runtime, no project context required.
#
# Public API:
#   dispatch_harvest_find_inflight    most recent in-flight UUID for (task, node)
#   dispatch_harvest_probe_remote     ssh probe — exit:<rc> | running | absent
#   dispatch_harvest_fetch            rsync log + exit, prints exit code
#   dispatch_harvest_attempt          full pipeline (probe → wait → fetch)

[ "${_LIB_DISPATCH_HARVEST_LOADED:-}" = "1" ] && return 0
_LIB_DISPATCH_HARVEST_LOADED=1

# resolve_runtime_global from lib-paths.sh; dispatch_registry_dir from
# lib-dispatch-registry.sh. Caller sources both before sourcing this lib.
if ! type resolve_runtime_global >/dev/null 2>&1; then
  printf 'lib-dispatch-harvest.sh: lib-paths.sh must be sourced first\n' >&2
  return 1
fi
if ! type dispatch_registry_dir >/dev/null 2>&1; then
  printf 'lib-dispatch-harvest.sh: lib-dispatch-registry.sh must be sourced first\n' >&2
  return 1
fi

# Most recent (by ISO-8601 dispatched_at, lexically sortable) registry entry
# whose status == "in-flight" AND task_id + node match. Stdout = lowercase
# UUID; exit 0. Empty stdout + exit 1 if no candidate exists.
dispatch_harvest_find_inflight() {
  local task_id="${1:?usage: dispatch_harvest_find_inflight <task_id> <node>}"
  local node="${2:?usage: dispatch_harvest_find_inflight <task_id> <node>}"
  local dir picked
  dir=$(dispatch_registry_dir) || return 1
  [ -d "$dir" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  picked=$(
    for f in "$dir"/*.json; do
      [ -r "$f" ] || continue
      jq -r --arg tid "$task_id" --arg n "$node" '
        select(.status == "in-flight"
               and .task_id == $tid
               and .node == $n)
        | "\(.dispatched_at)\t\(.uuid)"
      ' "$f" 2>/dev/null
    done | sort | tail -1 | awk -F'\t' '{print $2}'
  )
  [ -z "$picked" ] && return 1
  printf '%s\n' "$picked"
}

# Resolve `<user>@<host>` for a registered, enabled node by reading
# nodes.json. Mirrors node-dispatch.sh's resolution. Exit 1 if missing,
# disabled, or registry can't be parsed — caller treats as harvest miss.
_dispatch_harvest_user_host() {
  local node_id="${1:?}"
  local registry node_json enabled host user_
  registry="$(resolve_runtime_global)/nodes.json"
  [ -r "$registry" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  node_json=$(jq -r -e --arg id "$node_id" \
    '.nodes[]? | select(.id == $id)' "$registry" 2>/dev/null) || return 1
  enabled=$(printf '%s' "$node_json" | jq -r 'if .enabled == false then "false" else "true" end')
  [ "$enabled" = "true" ] || return 1
  host=$(printf '%s' "$node_json" | jq -r '.host // empty')
  user_=$(printf '%s' "$node_json" | jq -r '.user // empty')
  [ -n "$host" ] && [ -n "$user_" ] || return 1
  printf '%s@%s\n' "$user_" "$host"
}

# SSH options must match node-dispatch.sh so harvest probes time out the
# same way a fresh dispatch would (10s connect, BatchMode, accept-new).
_dispatch_harvest_ssh_opts() {
  printf -- '-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new'
}

# Single-round-trip probe. Stdout is one of:
#   exit:<rc>   — <uuid>.exit exists; rc is the exit code
#   running     — <uuid>.log exists but <uuid>.exit does not
#   absent      — neither file exists
# Exit 0 on a definitive answer; non-zero on ssh failure (caller treats as
# harvest miss + falls through to retry).
#
# REVIEW R3 carve-out: the heredoc body runs on the remote worker, which
# does not source lib-paths.sh. The literal `$HOME/.dev-studio/.runtime/logs`
# mirrors `resolve_runtime_global` on the worker — same exception
# node-dispatch.sh's REMOTE_WRAPPER documents. Keep both sides in sync.
dispatch_harvest_probe_remote() {
  local node_id="${1:?usage: dispatch_harvest_probe_remote <node> <uuid>}"
  local uuid="${2:?usage: dispatch_harvest_probe_remote <node> <uuid>}"
  local user_host
  user_host=$(_dispatch_harvest_user_host "$node_id") || return 1
  # shellcheck disable=SC2046
  ssh $(_dispatch_harvest_ssh_opts) "$user_host" -- bash -s -- "$uuid" <<'PROBE_EOF'
set -u
UUID="$1"
LOG_DIR="$HOME/.dev-studio/.runtime/logs"
LOG="$LOG_DIR/$UUID.log"
EXIT_FILE="$LOG_DIR/$UUID.exit"
if [ -r "$EXIT_FILE" ]; then
  rc=$(tr -d '[:space:]' < "$EXIT_FILE" 2>/dev/null)
  case "$rc" in ''|*[!0-9]*) rc=255 ;; esac
  printf 'exit:%s\n' "$rc"
elif [ -r "$LOG" ]; then
  printf 'running\n'
else
  printf 'absent\n'
fi
PROBE_EOF
}

# Pull <uuid>.log + <uuid>.exit from the worker. Writes the log to
# `<local_log_dest>` and prints the exit code (read from .exit) to stdout.
# Returns 0 on success, 1 on any I/O failure.
dispatch_harvest_fetch() {
  local node_id="${1:?usage: dispatch_harvest_fetch <node> <uuid> <local_log_dest>}"
  local uuid="${2:?}"
  local local_log="${3:?}"
  local user_host remote_log remote_exit local_exit ssh_opts rc
  user_host=$(_dispatch_harvest_user_host "$node_id") || return 1
  ssh_opts=$(_dispatch_harvest_ssh_opts)
  # Worker paths are home-relative. rsync's `<host>:relpath` form anchors
  # at the remote $HOME, matching how lib-source-sync stages worktrees.
  remote_log=".dev-studio/.runtime/logs/$uuid.log"
  remote_exit=".dev-studio/.runtime/logs/$uuid.exit"
  local_exit=$(mktemp 2>/dev/null) || local_exit="/tmp/harvest-exit-$$"
  # shellcheck disable=SC2086
  rsync -e "ssh $ssh_opts" -t "$user_host:$remote_log" "$local_log" >/dev/null 2>&1 || {
    rm -f "$local_exit" 2>/dev/null
    return 1
  }
  # shellcheck disable=SC2086
  rsync -e "ssh $ssh_opts" -t "$user_host:$remote_exit" "$local_exit" >/dev/null 2>&1 || {
    rm -f "$local_exit" 2>/dev/null
    return 1
  }
  rc=$(tr -d '[:space:]' < "$local_exit" 2>/dev/null)
  rm -f "$local_exit" 2>/dev/null
  case "$rc" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$rc"
}

# Top-level entry. Probes; if running, tail-streams the log to stderr while
# polling for the exit file (cap = STUDIO_HARVEST_TIMEOUT_S, default 1800);
# fetches log + exit on success. Stdout = harvested exit code; exit 0 on
# successful harvest, 1 if probe is absent or wait timed out.
#
# Tail goes to stderr so callers can pipe stdout into a build_log var
# without contaminating it. The log itself is rsync'd separately into
# `<local_log_dest>` as the canonical record for downstream parsing.
dispatch_harvest_attempt() {
  local node_id="${1:?usage: dispatch_harvest_attempt <node> <uuid> <local_log_dest>}"
  local uuid="${2:?}"
  local local_log="${3:?}"
  local probe rc fetched_rc
  probe=$(dispatch_harvest_probe_remote "$node_id" "$uuid" 2>/dev/null) || return 1
  case "$probe" in
    exit:*) ;;
    running)
      local cap user_host ssh_opts tail_pid deadline now
      cap="${STUDIO_HARVEST_TIMEOUT_S:-1800}"
      case "$cap" in ''|*[!0-9]*) cap=1800 ;; esac
      printf 'dispatch-harvest: prior dispatch %s on %s still in-flight; tailing up to %ss\n' \
        "$uuid" "$node_id" "$cap" >&2
      user_host=$(_dispatch_harvest_user_host "$node_id") || return 1
      ssh_opts=$(_dispatch_harvest_ssh_opts)
      # shellcheck disable=SC2086
      ssh $ssh_opts "$user_host" -- \
        "tail -F \"\$HOME/.dev-studio/.runtime/logs/$uuid.log\" 2>/dev/null" >&2 &
      tail_pid=$!
      deadline=$(( $(date -u +%s) + cap ))
      while :; do
        probe=$(dispatch_harvest_probe_remote "$node_id" "$uuid" 2>/dev/null) || break
        case "$probe" in exit:*) break ;; esac
        now=$(date -u +%s)
        [ "$now" -ge "$deadline" ] && break
        sleep 5
      done
      kill "$tail_pid" 2>/dev/null || true
      wait "$tail_pid" 2>/dev/null || true
      case "$probe" in exit:*) ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  rc="${probe#exit:}"
  case "$rc" in ''|*[!0-9]*) return 1 ;; esac
  fetched_rc=$(dispatch_harvest_fetch "$node_id" "$uuid" "$local_log") || return 1
  # The fetched .exit file is authoritative — the probe could have observed
  # it mid-write before lib-paths.sh-style atomic writes were added on the
  # worker (#269 uses mv-from-tmp; this is belt-and-braces).
  printf '%s\n' "$fetched_rc"
}
