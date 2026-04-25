#!/usr/bin/env bash
# configure.sh — post-install configuration for the studio.
#
# bootstrap.sh handles initial setup (one-shot mode: `bootstrap.sh --yes
# --role manager`). After that, this script is the single entry point
# for tweaks: managing workers, editing the manifest, toggling the
# scheduled worker-sync.
#
# Usage
#   scripts/configure.sh                       # interactive menu
#   scripts/configure.sh status                # one-screen status dump
#   scripts/configure.sh worker add            # interactively add a worker
#   scripts/configure.sh worker remove <id>    # remove a worker
#   scripts/configure.sh worker enable <id>    # flip enabled: true
#   scripts/configure.sh worker disable <id>   # flip enabled: false
#   scripts/configure.sh worker list           # tabular list
#   scripts/configure.sh manifest              # edit worker-manifest.yaml in $EDITOR
#   scripts/configure.sh schedule on           # install scheduled worker-sync
#   scripts/configure.sh schedule off          # remove it
#   scripts/configure.sh schedule status       # show launchd state + last log
#   scripts/configure.sh schedule run          # one-shot sync now
#   scripts/configure.sh recheck               # re-run role validation; surface diff
#                                              # vs last-recorded state. Use after
#                                              # installing Xcode / fixing SSH / etc.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

# ---------- ANSI helpers ----------
if [ -t 1 ]; then
  c_cyan=$'\033[1;36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
  c_blue=$'\033[34m'; c_red=$'\033[31m'; c_dim=$'\033[2m'
  c_bold=$'\033[1m'; c_reset=$'\033[0m'
else
  c_cyan=''; c_green=''; c_yellow=''; c_blue=''; c_red=''; c_dim=''; c_bold=''; c_reset=''
fi
ok()   { printf '  %s✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$c_yellow" "$c_reset" "$*"; }
info() { printf '  %si%s %s\n' "$c_blue" "$c_reset" "$*"; }
err()  { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }

# ---------- common ----------
NODES_JSON="$(resolve_runtime_global)/nodes.json"
PROJECT=$(resolve_project 2>/dev/null || echo "")
MANIFEST=""
if [ -n "$PROJECT" ]; then
  MANIFEST="$(resolve_project_root_for "$PROJECT")/worker-manifest.yaml"
fi

require_jq() { command -v jq >/dev/null 2>&1 || { err "jq required"; exit 2; }; }
ensure_nodes_json() {
  if [ ! -f "$NODES_JSON" ]; then
    mkdir -p "$(dirname "$NODES_JSON")"
    printf '{"schema":1,"nodes":[]}\n' > "$NODES_JSON"
  fi
}

# ============================================================================
# status
# ============================================================================
cmd_status() {
  printf '%sStudio configuration status%s\n\n' "$c_bold" "$c_reset"

  printf '  %sProject:%s %s\n' "$c_dim" "$c_reset" "${PROJECT:-(none — not in a git repo)}"
  if [ -x "$SCRIPT_DIR/machine-id.sh" ]; then
    printf '  %sMachine-id:%s %s\n' "$c_dim" "$c_reset" "$("$SCRIPT_DIR/machine-id.sh" 2>/dev/null || echo unknown)"
  fi

  echo
  printf '%sRegistered workers (nodes.json)%s\n' "$c_bold" "$c_reset"
  if [ -f "$NODES_JSON" ] && command -v jq >/dev/null 2>&1; then
    local count
    count=$(jq -r '.nodes | length' "$NODES_JSON" 2>/dev/null || echo 0)
    if [ "$count" = "0" ]; then
      info "(none — agents-only mode; all dispatches run locally)"
    else
      printf '  %-12s %-30s %-12s %-30s %s\n' "ID" "HOST" "ENABLED" "ROLES" "USER"
      jq -r '.nodes[]? | [.id, (.host // "-"), (if .enabled == false then "no" else "yes" end), ((.roles // []) | join(",")), (.user // "-")] | @tsv' "$NODES_JSON" 2>/dev/null \
        | while IFS=$'\t' read -r id host enabled roles user; do
            printf '  %-12s %-30s %-12s %-30s %s\n' "$id" "$host" "$enabled" "$roles" "$user"
          done
    fi
  else
    info "(no nodes.json yet at $NODES_JSON)"
  fi

  echo
  printf '%sWorker manifest%s\n' "$c_bold" "$c_reset"
  if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
    ok "$MANIFEST"
    if command -v yq >/dev/null 2>&1; then
      local req opt xc
      req=$(yq -r '.brew_packages.required[]?' "$MANIFEST" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
      opt=$(yq -r '.brew_packages.optional[]?' "$MANIFEST" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
      xc=$(yq -r '.xcode_version_min // ""' "$MANIFEST" 2>/dev/null)
      [ -n "$req" ] && info "required brew: $req"
      [ -n "$opt" ] && info "optional brew: $opt"
      [ -n "$xc"  ] && info "xcode_min:     $xc"
    fi
  else
    info "(no manifest — run: scripts/configure.sh manifest, or scripts/init-worker-manifest.sh)"
  fi

  echo
  printf '%sScheduled worker-sync%s\n' "$c_bold" "$c_reset"
  if [ -f "$HOME/Library/LaunchAgents/dev.studio.worker-sync.plist" ]; then
    if launchctl print "gui/$(id -u)/dev.studio.worker-sync" >/dev/null 2>&1; then
      ok "ACTIVE"
    else
      warn "plist present but not loaded — try: scripts/schedule-worker-sync.sh --install"
    fi
  else
    info "(not scheduled — run: scripts/configure.sh schedule on)"
  fi
}

# ============================================================================
# worker subcommand
# ============================================================================
cmd_worker() {
  require_jq
  ensure_nodes_json
  local sub="${1:-list}"
  case "$sub" in
    list)
      cmd_status | sed -n '/Registered workers/,/^$/p'
      ;;
    add)
      local id host user roles
      printf '%s? id (short, used in lock paths and event logs):%s ' "$c_dim" "$c_reset"; read -r id
      [ -z "$id" ] && { err "id required"; exit 1; }
      printf '%s? host (Tailscale magic-DNS or LAN):%s ' "$c_dim" "$c_reset"; read -r host
      printf '%s? remote user [%s]:%s ' "$c_dim" "$(id -un)" "$c_reset"; read -r user
      [ -z "$user" ] && user=$(id -un)
      printf '%s? roles, comma-separated [swift-test,xcodebuild]:%s ' "$c_dim" "$c_reset"; read -r roles
      [ -z "$roles" ] && roles="swift-test,xcodebuild"
      local roles_json
      roles_json=$(printf '%s' "$roles" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
      jq --arg id "$id" --arg host "$host" --arg user "$user" --argjson roles "$roles_json" \
         '.nodes += [{id:$id, host:$host, user:$user, roles:$roles, enabled:true}]' \
         "$NODES_JSON" > "$NODES_JSON.tmp" && mv "$NODES_JSON.tmp" "$NODES_JSON"
      ok "added worker '$id'"
      ;;
    remove)
      local id="${2:?usage: configure.sh worker remove <id>}"
      jq --arg id "$id" '.nodes |= map(select(.id != $id))' "$NODES_JSON" > "$NODES_JSON.tmp" \
        && mv "$NODES_JSON.tmp" "$NODES_JSON"
      ok "removed worker '$id'"
      ;;
    enable|disable)
      local id="${2:?usage: configure.sh worker $sub <id>}"
      local val=$([ "$sub" = "enable" ] && echo true || echo false)
      jq --arg id "$id" --argjson v "$val" \
         '.nodes |= map(if .id == $id then .enabled = $v else . end)' \
         "$NODES_JSON" > "$NODES_JSON.tmp" && mv "$NODES_JSON.tmp" "$NODES_JSON"
      ok "$sub'd worker '$id'"
      ;;
    *) err "unknown subcommand: $sub"; exit 1 ;;
  esac
}

# ============================================================================
# manifest
# ============================================================================
cmd_manifest() {
  if [ -z "$MANIFEST" ]; then err "no project resolved (not in a git repo)"; exit 2; fi
  if [ ! -f "$MANIFEST" ]; then
    info "manifest doesn't exist — creating default"
    "$SCRIPT_DIR/init-worker-manifest.sh"
  fi
  "${EDITOR:-vi}" "$MANIFEST"
  ok "edited: $MANIFEST"
}

# ============================================================================
# recheck — re-run validation hooks for the recorded role; surface diff vs
# last-known status. Useful after installing Xcode / fixing SSH keys / etc.
# ============================================================================
cmd_recheck() {
  # shellcheck source=lib-stepwise.sh
  . "$SCRIPT_DIR/lib-stepwise.sh"
  require_jq
  local state; state=$(stepwise_state_path)
  if [ ! -f "$state" ]; then
    info "no bootstrap-state.json yet — first \`bootstrap.sh\` run will populate it"
    info "running a one-shot validation against the current role anyway"
  fi
  # Derive role + worker_roles. State file is authoritative if present;
  # otherwise probe the local machine for sensible defaults.
  local role wroles
  role=$(jq -r '.role // ""' "$state" 2>/dev/null || true)
  wroles=$(jq -r '(.worker_roles // []) | join(",")' "$state" 2>/dev/null || true)
  if [ -z "$role" ]; then
    if [ -L "$HOME/.claude/skills/chanakya" ]; then role="manager"; else role="worker"; fi
  fi
  [ -z "$wroles" ] && wroles="swift-test,xcodebuild"
  printf '%sRecheck%s — role=%s worker_roles=%s\n\n' "$c_bold" "$c_reset" "$role" "$wroles"
  stepwise_recheck_all "$role" "$wroles"
}

# ============================================================================
# schedule
# ============================================================================
cmd_schedule() {
  local sub="${1:-status}"
  case "$sub" in
    on|install)   "$SCRIPT_DIR/schedule-worker-sync.sh" --install ;;
    off|uninstall) "$SCRIPT_DIR/schedule-worker-sync.sh" --uninstall ;;
    status)       "$SCRIPT_DIR/schedule-worker-sync.sh" --status ;;
    run|run-now)  "$SCRIPT_DIR/schedule-worker-sync.sh" --run-now ;;
    *) err "unknown subcommand: $sub (want on|off|status|run)"; exit 1 ;;
  esac
}

# ============================================================================
# interactive menu (no args)
# ============================================================================
interactive_menu() {
  cmd_status
  echo
  cat <<MENU
${c_bold}What would you like to do?${c_reset}

  ${c_bold}1${c_reset}  Add a worker
  ${c_bold}2${c_reset}  Remove a worker
  ${c_bold}3${c_reset}  Enable / disable a worker
  ${c_bold}4${c_reset}  Edit worker manifest
  ${c_bold}5${c_reset}  Toggle scheduled worker-sync (on/off)
  ${c_bold}6${c_reset}  Run worker-sync now
  ${c_bold}7${c_reset}  Recheck — re-validate role; report what changed since last bootstrap
  ${c_bold}q${c_reset}  Quit
MENU
  printf '\n? '
  read -r choice
  case "$choice" in
    1) cmd_worker add ;;
    2) printf '? worker id to remove: '; read -r id; cmd_worker remove "$id" ;;
    3) printf '? worker id: '; read -r id
       printf '? enable or disable [e/d]: '; read -r ed
       case "$ed" in e|E|enable) cmd_worker enable "$id" ;; d|D|disable) cmd_worker disable "$id" ;; esac ;;
    4) cmd_manifest ;;
    5) cmd_schedule status
       printf '? toggle [on/off]: '; read -r toggle
       cmd_schedule "$toggle" ;;
    6) cmd_schedule run ;;
    7) cmd_recheck ;;
    *) ok "bye" ;;
  esac
}

# ============================================================================
# dispatch
# ============================================================================
case "${1:-menu}" in
  status)        cmd_status ;;
  worker)        shift; cmd_worker "$@" ;;
  manifest)      cmd_manifest ;;
  schedule)      shift; cmd_schedule "$@" ;;
  recheck)       cmd_recheck ;;
  menu|"")       interactive_menu ;;
  -h|--help)     sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) err "unknown command: $1 (try: status / worker / manifest / schedule / recheck / menu)"; exit 1 ;;
esac
