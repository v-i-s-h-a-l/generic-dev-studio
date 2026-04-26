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
#   scripts/configure.sh guide                 # guided post-setup walkthrough — explore
#                                              # tools, workers, networking, scheduling
#   scripts/configure.sh tour                  # quick tour of the studio architecture

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ui.sh
. "$SCRIPT_DIR/lib-ui.sh"
# shellcheck source=lib-registry.sh
. "$SCRIPT_DIR/lib-registry.sh"

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

      # #146 — probe the worker's stable machine_id via SSH so registry has a
      # durability backing key (id is grep-friendly but reusable across boxes;
      # machine_id catches reinstalls and accidental id collisions).
      local probed_mid=""
      if [ -n "$host" ]; then
        probed_mid=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
          "${user}@${host}" 'cat ~/.dev-studio/.runtime/machine-id 2>/dev/null' 2>/dev/null \
          | tr -d '[:space:]')
        if [ -z "$probed_mid" ]; then
          info "could not probe machine-id on $host (worker may not be bootstrapped yet); registering without machine_id — re-run after bootstrap to add it"
        fi
      fi

      # Collision check: if id is already taken by a *different* physical
      # machine, refuse loud rather than silently rebind events/lock paths.
      # Missing machine_id on the existing entry → skip (back-compat).
      local existing_mid
      existing_mid=$(jq -r --arg id "$id" '.nodes[]? | select(.id == $id) | .machine_id // ""' "$NODES_JSON" 2>/dev/null)
      if [ -n "$existing_mid" ] && [ -n "$probed_mid" ] && [ "$existing_mid" != "$probed_mid" ]; then
        err "id '$id' is already registered to a different machine (machine_id $existing_mid; probed $probed_mid). Pick another id or remove the stale entry first."
        exit 2
      fi

      local roles_json
      roles_json=$(printf '%s' "$roles" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
      # Build the entry with machine_id only when probed — keeps optional
      # field truly optional (back-compat with hand-edited registries).
      if [ -n "$probed_mid" ]; then
        jq --arg id "$id" --arg host "$host" --arg user "$user" --arg mid "$probed_mid" --argjson roles "$roles_json" \
           '.nodes |= ([.[]? | select(.id != $id)] + [{id:$id, machine_id:$mid, host:$host, user:$user, roles:$roles, enabled:true}])' \
           "$NODES_JSON" > "$NODES_JSON.tmp" && mv "$NODES_JSON.tmp" "$NODES_JSON"
      else
        jq --arg id "$id" --arg host "$host" --arg user "$user" --argjson roles "$roles_json" \
           '.nodes |= ([.[]? | select(.id != $id)] + [{id:$id, host:$host, user:$user, roles:$roles, enabled:true}])' \
           "$NODES_JSON" > "$NODES_JSON.tmp" && mv "$NODES_JSON.tmp" "$NODES_JSON"
      fi
      ok "added worker '$id'${probed_mid:+ (machine_id ${probed_mid:0:12}…)}"
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
# guide — post-setup guided configuration wizard
#
# Walks the user through their setup topic-by-topic, with explanations,
# current state, and change options. Uses the tool registry (tools.yaml)
# for the Tools topic so new tools auto-appear.
# ============================================================================

_guide_resolve_role() {
  local state role wroles
  state=""
  if [ -x "$SCRIPT_DIR/lib-stepwise.sh" ]; then
    . "$SCRIPT_DIR/lib-stepwise.sh"
    state=$(stepwise_state_path 2>/dev/null || echo "")
  fi
  _GUIDE_ROLE=""
  _GUIDE_WROLES=""
  if [ -n "$state" ] && [ -f "$state" ] && command -v jq >/dev/null 2>&1; then
    _GUIDE_ROLE=$(jq -r '.role // ""' "$state" 2>/dev/null || true)
    _GUIDE_WROLES=$(jq -r '(.worker_roles // []) | join(",")' "$state" 2>/dev/null || true)
  fi
  [ -z "$_GUIDE_ROLE" ] && {
    if [ -L "$HOME/.claude/skills/chanakya" ]; then _GUIDE_ROLE="manager"; else _GUIDE_ROLE="worker"; fi
  }
}

_guide_tools() {
  printf '\n%s━━━ Tools ━━━%s\n\n' "$c_cyan" "$c_reset"
  info "Role: $_GUIDE_ROLE"
  [ -n "$_GUIDE_WROLES" ] && info "Worker roles: $_GUIDE_WROLES"
  echo

  registry_load
  registry_scan "$_GUIDE_ROLE" "$_GUIDE_WROLES"
  registry_render_scan "interactive"

  local count_need=0 count_opt=0
  local entry
  for entry in $_SCAN_NEEDED; do count_need=$((count_need + 1)); done
  for entry in $_SCAN_OPTIONAL; do count_opt=$((count_opt + 1)); done

  if [ "$count_need" -gt 0 ] || [ "$count_opt" -gt 0 ]; then
    echo
    if confirm "Install missing tools now?" "y"; then
      YES=0 registry_install_needed "interactive" || true
    fi
  else
    echo
    ok "All tools for your role are installed."
  fi

  echo
  printf '  %sTip:%s Type a tool ID to see full details (e.g. "jq", "tailscale"), or Enter to go back.\n' "$c_dim" "$c_reset"
  printf '  ? '
  read -r tool_choice
  if [ -n "$tool_choice" ]; then
    local _tid
    _tid=$(registry_get "$tool_choice" "id")
    if [ -n "$_tid" ]; then
      registry_tool_card "$tool_choice"
    else
      warn "Unknown tool: $tool_choice"
    fi
  fi
}

_guide_networking() {
  printf '\n%s━━━ Networking ━━━%s\n\n' "$c_cyan" "$c_reset"

  printf '  %sTailscale%s\n' "$c_bold" "$c_reset"
  if command -v tailscale >/dev/null 2>&1; then
    if tailscale status >/dev/null 2>&1; then
      ok "Tailscale connected: $(tailscale version 2>/dev/null | head -1)"
      local ts_name
      ts_name=$(tailscale status --json 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null || true)
      [ -n "$ts_name" ] && info "DNS name: $ts_name"
    else
      warn "Tailscale installed but not connected"
      cmd_hint "open -a Tailscale   # or: sudo tailscale up"
    fi
  else
    warn "Tailscale not installed"
    info "Mesh VPN for reaching workers by hostname. Free for personal use."
    cmd_hint "brew install --cask tailscale"
  fi

  echo
  printf '  %sSSH%s\n' "$c_bold" "$c_reset"
  if [ -f "$HOME/.ssh/id_ed25519" ] || [ -f "$HOME/.ssh/id_rsa" ]; then
    ok "SSH keypair present"
  else
    warn "No SSH keypair found"
    cmd_hint "ssh-keygen -t ed25519 -C \"$(id -un)@studio\""
  fi

  local rl_state
  rl_state=$(sudo -n systemsetup -getremotelogin 2>/dev/null | awk -F': ' '{print tolower($NF)}' | tr -d ' ' || echo "unknown")
  case "$rl_state" in
    on)      ok "Remote Login (SSH server) enabled" ;;
    off)     warn "Remote Login is OFF — workers can't accept dispatches"
             cmd_hint "sudo systemsetup -setremotelogin on" ;;
    unknown) info "Remote Login status unknown (needs sudo to check)" ;;
  esac
}

_guide_tour() {
  printf '\n%s━━━ Quick Tour ━━━%s\n\n' "$c_cyan" "$c_reset"
  cat <<'TOUR'
  The studio has three layers:

  1. AGENTS — AI-powered task management
     /chanakya plans work, /achilles implements, /argus reviews.
     They run inside Claude Code on your manager machine.

  2. DISPATCH — distributed builds
     Your manager sends compile/test work to registered workers
     via SSH. rsync keeps sources in sync; gtimeout prevents runaways.

  3. TOOLING — scripts and configuration
     Everything under scripts/ — health checks, sync, scheduling,
     event logging. Most scripts are idempotent and re-runnable.

  Key files:
    ~/.dev-studio/.runtime/nodes.json          worker registry
    ~/.dev-studio/.runtime/bootstrap-state.json wizard state
    ~/.dev-studio/<project>/                    per-project runtime

  Commands:
    scripts/configure.sh status      see everything at a glance
    scripts/configure.sh recheck     re-validate your setup
    scripts/configure.sh worker add  register a new worker
    scripts/configure.sh guide       this walkthrough
    scripts/bootstrap.sh             re-run the full wizard
    scripts/bootstrap.sh --quick     quick-start (tools + skills only)

TOUR
}

cmd_guide() {
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq is not installed — some guide features need it."
    cmd_hint "brew install jq   # or: scripts/bootstrap.sh"
    echo
  fi

  _guide_resolve_role

  printf '\n%s━━━ Studio Configuration Guide ━━━%s\n\n' "$c_cyan" "$c_reset"
  info "Role: $_GUIDE_ROLE"
  [ -n "$_GUIDE_WROLES" ] && info "Worker roles: $_GUIDE_WROLES"
  echo

  local _loop=1
  while [ "$_loop" = "1" ]; do
    cat <<MENU
  ${c_bold}What would you like to explore?${c_reset}

    ${c_bold}1${c_reset}  Tools         — see what's installed, add optional tools
    ${c_bold}2${c_reset}  Workers       — manage worker machines
    ${c_bold}3${c_reset}  Networking    — Tailscale, SSH, hostname resolution
    ${c_bold}4${c_reset}  Scheduling    — automated worker-sync
    ${c_bold}5${c_reset}  Health check  — re-validate your setup, spot regressions
    ${c_bold}6${c_reset}  Quick tour    — what each piece does (2-min read)
    ${c_bold}q${c_reset}  Exit
MENU
    printf '\n  ? '
    read -r guide_choice

    case "$guide_choice" in
      1) _guide_tools ;;
      2) cmd_worker list
         echo
         if confirm "Add a worker?" "n"; then cmd_worker add; fi ;;
      3) _guide_networking ;;
      4) cmd_schedule status
         echo
         if confirm "Toggle scheduling?" "n"; then
           printf '  on or off? '
           read -r toggle
           cmd_schedule "$toggle"
         fi ;;
      5) cmd_recheck ;;
      6) _guide_tour ;;
      q|Q|"") _loop=0 ;;
      *) warn "Pick 1-6 or q" ;;
    esac
    echo
  done
  ok "bye"
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
  guide)         cmd_guide ;;
  tour)          _guide_resolve_role; _guide_tour ;;
  menu|"")       interactive_menu ;;
  -h|--help)     sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) err "unknown command: $1 (try: status / worker / manifest / schedule / recheck / guide / tour / menu)"; exit 1 ;;
esac
