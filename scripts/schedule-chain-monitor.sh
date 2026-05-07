#!/usr/bin/env bash
# schedule-chain-monitor.sh - install/status/remove the chain monitor LaunchAgent.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
MANAGER="$SCRIPT_DIR/manager-chain-monitor.sh"

# shellcheck source=lib-chain-monitor-config.sh disable=SC1091
. "$SCRIPT_DIR/lib-chain-monitor-config.sh"

ACTION=""
PROJECT=""
OWNER_HOME_OVERRIDE=""
LIST_ID="${STUDIO_CHAIN_MONITOR_SLACK_LIST_ID:-${CHAIN_MONITOR_SLACK_LIST_ID:-}}"
INTERVAL_S="${CHAIN_MONITOR_SCHEDULER_INTERVAL_S:-60}"
DRY_RUN=0

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/schedule-chain-monitor.sh --install [--project <slug>] [--list-id <id>] [--interval-s <seconds>] [--dry-run]
  scripts/schedule-chain-monitor.sh --uninstall [--project <slug>] [--dry-run]
  scripts/schedule-chain-monitor.sh --status [--project <slug>]
  scripts/schedule-chain-monitor.sh --run-now [--project <slug>] [--list-id <id>]

Scheduling is macOS LaunchAgent-only. The agent is always owned by the login
home; synthetic HOME paths are refused as LaunchAgent owners.
EOF
  exit 2
}

sanitize_label_part() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

resolve_scheduler_owner_home() {
  if [ -n "$OWNER_HOME_OVERRIDE" ]; then
    printf '%s\n' "$OWNER_HOME_OVERRIDE"
    return 0
  fi
  if [ -n "${STUDIO_CHAIN_MONITOR_OWNER_HOME:-}" ]; then
    printf '%s\n' "$STUDIO_CHAIN_MONITOR_OWNER_HOME"
    return 0
  fi
  chain_monitor_data_home
}

require_macos_for_schedule() {
  local kernel="${STUDIO_CHAIN_MONITOR_UNAME:-$(uname -s)}"
  [ "$kernel" = "Darwin" ] || {
    printf 'schedule-chain-monitor: LaunchAgent scheduling is macOS-only in this phase (got %s)\n' "$kernel" >&2
    exit 2
  }
}

refuse_synthetic_owner() {
  local owner_home="$1"
  if studio_home_is_synthetic "$owner_home"; then
    printf 'schedule-chain-monitor: refusing synthetic-home LaunchAgent ownership: %s\n' "$owner_home" >&2
    printf 'schedule-chain-monitor: rerun with a login-home owner or STUDIO_CHAIN_MONITOR_OWNER_HOME=<login-home>\n' >&2
    exit 2
  fi
}

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

plist_xml() {
  local label="$1" owner_home="$2" project="$3" log_dir="$4" list_id="$5" escaped_manager escaped_home escaped_project escaped_log escaped_list
  escaped_manager=$(printf '%s' "$MANAGER" | xml_escape)
  escaped_home=$(printf '%s' "$owner_home" | xml_escape)
  escaped_project=$(printf '%s' "$project" | xml_escape)
  escaped_log=$(printf '%s' "$log_dir" | xml_escape)
  escaped_list=$(printf '%s' "$list_id" | xml_escape)
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${escaped_manager}</string>
    <string>sync</string>
    <string>--project</string>
    <string>${escaped_project}</string>
  </array>
  <key>StartInterval</key>
  <integer>${INTERVAL_S}</integer>
  <key>StandardOutPath</key>
  <string>${escaped_log}/chain-monitor-sync.out.log</string>
  <key>StandardErrorPath</key>
  <string>${escaped_log}/chain-monitor-sync.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${escaped_home}</string>
    <key>ACHILLES_PROJECT</key>
    <string>${escaped_project}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
PLIST
  if [ -n "$list_id" ]; then
    cat <<PLIST
    <key>STUDIO_CHAIN_MONITOR_SLACK_LIST_ID</key>
    <string>${escaped_list}</string>
PLIST
  fi
  cat <<'PLIST'
  </dict>
</dict>
</plist>
PLIST
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install) ACTION="install"; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --status) ACTION="status"; shift ;;
    --run-now) ACTION="run-now"; shift ;;
    --project) PROJECT="${2:?--project requires a value}"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --owner-home) OWNER_HOME_OVERRIDE="${2:?--owner-home requires a path}"; shift 2 ;;
    --owner-home=*) OWNER_HOME_OVERRIDE="${1#--owner-home=}"; shift ;;
    --list-id) LIST_ID="${2:?--list-id requires a value}"; shift 2 ;;
    --list-id=*) LIST_ID="${1#--list-id=}"; shift ;;
    --interval-s) INTERVAL_S="${2:?--interval-s requires a value}"; shift 2 ;;
    --interval-s=*) INTERVAL_S="${1#--interval-s=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) printf 'schedule-chain-monitor: unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done

[ -n "$ACTION" ] || usage
PROJECT="${PROJECT:-$(resolve_project)}"
case "$INTERVAL_S" in ''|*[!0-9]*) printf 'schedule-chain-monitor: --interval-s must be a positive integer\n' >&2; exit 2 ;; esac
[ "$INTERVAL_S" -gt 0 ] || { printf 'schedule-chain-monitor: --interval-s must be > 0\n' >&2; exit 2; }

OWNER_HOME=$(resolve_scheduler_owner_home)
refuse_synthetic_owner "$OWNER_HOME"

LABEL="dev.studio.chain-monitor-sync.$(sanitize_label_part "$PROJECT")"
PLIST_PATH="$OWNER_HOME/Library/LaunchAgents/${LABEL}.plist"
PROJECT_ROOT=$(HOME="$OWNER_HOME" resolve_project_root_for "$PROJECT")
LOG_DIR="$PROJECT_ROOT/.runtime/logs"

case "$ACTION" in
  install)
    require_macos_for_schedule
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'owner_home=%s\n' "$OWNER_HOME" >&2
      printf 'plist=%s\n' "$PLIST_PATH" >&2
      plist_xml "$LABEL" "$OWNER_HOME" "$PROJECT" "$LOG_DIR" "$LIST_ID"
      exit 0
    fi
    mkdir -p "$LOG_DIR" "$(dirname "$PLIST_PATH")"
    plist_xml "$LABEL" "$OWNER_HOME" "$PROJECT" "$LOG_DIR" "$LIST_ID" > "$PLIST_PATH"
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null \
      || launchctl load "$PLIST_PATH"
    printf 'installed=%s\n' "$LABEL"
    printf 'owner_home=%s\n' "$OWNER_HOME"
    printf 'plist=%s\n' "$PLIST_PATH"
    ;;
  uninstall)
    require_macos_for_schedule
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would_uninstall=%s\n' "$LABEL"
      printf 'plist=%s\n' "$PLIST_PATH"
      exit 0
    fi
    if [ -f "$PLIST_PATH" ]; then
      launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null \
        || launchctl unload "$PLIST_PATH" 2>/dev/null \
        || true
      rm -f "$PLIST_PATH"
      printf 'uninstalled=%s\n' "$LABEL"
    else
      printf 'not_installed=%s\n' "$LABEL"
    fi
    ;;
  status)
    require_macos_for_schedule
    printf 'owner_home=%s\n' "$OWNER_HOME"
    printf 'plist=%s\n' "$PLIST_PATH"
    if command -v launchctl >/dev/null 2>&1 && launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      printf 'status=active\n'
    elif [ -f "$PLIST_PATH" ]; then
      printf 'status=installed\n'
    else
      printf 'status=not_installed\n'
    fi
    ;;
  run-now)
    run_args=(sync --project "$PROJECT")
    [ -n "$LIST_ID" ] && run_args+=(--list-id "$LIST_ID")
    exec env HOME="$OWNER_HOME" "$MANAGER" "${run_args[@]}"
    ;;
  *) usage ;;
esac
