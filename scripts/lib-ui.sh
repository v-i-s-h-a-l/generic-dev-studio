#!/usr/bin/env bash
# lib-ui.sh — shared terminal UI primitives for studio scripts.
#
# Provides: ANSI colors, output functions (step/ok/warn/etc), prompt
# helpers (ask/confirm/pause_for_user), run() with heartbeat, summary
# accumulator, and tier badge renderers.
#
# Source this from any script that needs terminal output. It detects
# TTY state and FD availability automatically.
#
# FD contract: if the caller sets up FD 3 (terminal out) and FD 4
# (terminal in) — e.g. for tee-pipe bypass — prompts use those FDs.
# Otherwise, prompts fall back to stderr/stdin. Callers set up FDs
# AFTER sourcing this library; functions detect FDs at call time.
#
# Control variables (set by caller before sourcing or before calls):
#   UI_COLOR   0|1     Force color off/on (auto-detected from TTY if unset)
#   YES        0|1     1 = non-interactive (auto-accept defaults)
#   DRY_RUN    0|1     1 = run() prints commands instead of executing
#
# Guard: safe to source multiple times.

[ "${_LIB_UI_LOADED:-}" = "1" ] && return 0
_LIB_UI_LOADED=1

# ============================================================================
# ANSI colors — detected once at source time from the REAL stdout.
# Source this BEFORE any exec that redirects stdout (e.g. tee pipe).
# ============================================================================

if [ "${UI_COLOR:-}" = "" ]; then
  if [ -t 1 ]; then UI_COLOR=1; else UI_COLOR=0; fi
fi

if [ "$UI_COLOR" = "1" ]; then
  c_cyan=$'\033[1;36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
  c_blue=$'\033[34m'; c_red=$'\033[31m'; c_magenta=$'\033[35m'
  c_dim=$'\033[2m'; c_bold=$'\033[1m'; c_reset=$'\033[0m'
else
  c_cyan=''; c_green=''; c_yellow=''; c_blue=''; c_red=''; c_magenta=''
  c_dim=''; c_bold=''; c_reset=''
fi

# ============================================================================
# Output functions
# ============================================================================

step()     { printf '\n%s━━━ %s ━━━%s\n' "$c_cyan" "$*" "$c_reset"; }
substep()  { printf '\n  %s▸ %s%s\n' "$c_magenta" "$*" "$c_reset"; }
ok()       { printf '  %s✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()     { printf '  %s⚠%s %s\n' "$c_yellow" "$c_reset" "$*"; }
info()     { printf '  %si%s %s\n' "$c_blue" "$c_reset" "$*"; }
err()      { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
cmd_hint() { printf '  %s$ %s%s\n' "$c_dim" "$*" "$c_reset"; }
dim()      { printf '  %s%s%s\n' "$c_dim" "$*" "$c_reset"; }
announce() { printf '  %s↻%s %s %s(this can take a moment — heartbeat below if it runs long)%s\n' \
  "$c_blue" "$c_reset" "$*" "$c_dim" "$c_reset"; }

# ============================================================================
# Tier badges — colored labels for tool tiers
# ============================================================================

badge_required()    { printf '%sREQUIRED%s'    "$c_red$c_bold" "$c_reset"; }
badge_recommended() { printf '%sRECOMMENDED%s' "$c_yellow" "$c_reset"; }
badge_optional()    { printf '%sOPTIONAL%s'    "$c_dim" "$c_reset"; }

badge_for_tier() {
  case "${1:-}" in
    required)    badge_required ;;
    recommended) badge_recommended ;;
    optional)    badge_optional ;;
    *)           printf '%s' "$1" ;;
  esac
}

# ============================================================================
# Prompt FD resolution — detect FDs 3/4 at call time
# ============================================================================

_ui_out_fd() {
  if { : >&3; } 2>/dev/null; then printf '3'; else printf '2'; fi
}

_ui_in_fd() {
  if { : <&4; } 2>/dev/null; then printf '4'; else printf '0'; fi
}

# ============================================================================
# Prompt helpers
#
# YES=1 → non-interactive (auto-accept defaults, log the decision).
# FDs 3/4 → bypass tee pipe when open; fall back to stderr/stdin.
# ============================================================================

ask() {
  local prompt="$1" default="${2:-}" suffix="" reply _ofd _ifd
  _ofd=$(_ui_out_fd); _ifd=$(_ui_in_fd)
  [ -n "$default" ] && suffix=" [$default]"
  if [ "${YES:-0}" = "1" ]; then
    printf '  %s? %s%s — using default: %s%s\n' "$c_dim" "$prompt" "$suffix" "$default" "$c_reset" >&2
    printf '%s' "$default"
    return
  fi
  printf '  %s⌨  INPUT NEEDED%s  %s%s: ' "$c_yellow$c_bold" "$c_reset" "$prompt" "$suffix" >&"$_ofd"
  IFS= read -r reply <&"$_ifd" || reply=""
  reply="${reply:-$default}"
  printf '  %s⌨  %s → %s%s\n' "$c_dim" "$prompt" "$reply" "$c_reset" >&2
  printf '%s' "$reply"
}

confirm() {
  local prompt="$1" default="${2:-y}" suffix reply _ofd _ifd
  _ofd=$(_ui_out_fd); _ifd=$(_ui_in_fd)
  case "$default" in y|Y) suffix="[Y/n]" ;; *) suffix="[y/N]" ;; esac
  if [ "${YES:-0}" = "1" ]; then
    printf '  %s? %s %s — using default: %s%s\n' "$c_dim" "$prompt" "$suffix" "$default" "$c_reset" >&2
    case "$default" in y|Y) return 0 ;; *) return 1 ;; esac
  fi
  printf '  %s⌨  INPUT NEEDED%s  %s %s: ' "$c_yellow$c_bold" "$c_reset" "$prompt" "$suffix" >&"$_ofd"
  IFS= read -r reply <&"$_ifd" || reply=""
  reply="${reply:-$default}"
  case "$reply" in
    y|Y|yes|Yes) printf '  %s⌨  %s → yes%s\n' "$c_dim" "$prompt" "$c_reset" >&2; return 0 ;;
    *)           printf '  %s⌨  %s → no%s\n'  "$c_dim" "$prompt" "$c_reset" >&2; return 1 ;;
  esac
}

pause_for_user() {
  local _ofd _ifd
  _ofd=$(_ui_out_fd); _ifd=$(_ui_in_fd)
  if [ "${YES:-0}" = "1" ]; then dim "(non-interactive: skipping pause)"; return; fi
  printf '  %s⌨  INPUT NEEDED%s  Press Enter when done (or Ctrl-C to abort)…' \
    "$c_yellow$c_bold" "$c_reset" >&"$_ofd"
  IFS= read -r _ <&"$_ifd" || true
  printf '\n' >&"$_ofd"
}

# ============================================================================
# run() — execute a command with heartbeat + dry-run support
#
# In DRY_RUN mode, prints the command instead of executing.
# When a command produces no output for >=15s, prints an elapsed-time
# heartbeat so the user knows we're not wedged.
# ============================================================================

run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '  %sDRY-RUN: %s%s\n' "$c_dim" "$*" "$c_reset"
    return 0
  fi
  local start_ts hb_pid rc _ofd
  _ofd=$(_ui_out_fd)
  start_ts=$(date +%s)
  (
    sleep 15
    while :; do
      now=$(date +%s)
      printf '  %s⏳ still running… %ds elapsed%s\n' \
        "$c_dim" "$((now - start_ts))" "$c_reset" >&"$_ofd" 2>/dev/null || exit 0
      sleep 15
    done
  ) &
  hb_pid=$!
  "$@"
  rc=$?
  kill "$hb_pid" 2>/dev/null || true
  wait "$hb_pid" 2>/dev/null || true
  return $rc
}

# ============================================================================
# Summary accumulator — append lines, dump at the end
# ============================================================================

if [ -z "${SUMMARY_LINES+x}" ]; then
  declare -a SUMMARY_LINES
fi
summary() { SUMMARY_LINES+=("$1"); }
