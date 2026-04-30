#!/usr/bin/env bash
# monitor-install.sh — install/remove the laptop-side node monitor.
#
# Installs an opt-in LaunchAgent that runs scripts/node-monitor.sh hourly.
# The alert channel is configured through environment variables written to
# the plist at install time.

set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PLIST="$HOME/Library/LaunchAgents/dev.studio.node-monitor.plist"
LOG_DIR="$(resolve_runtime_global)/logs"
LABEL="dev.studio.node-monitor"

CHANNEL="${STUDIO_NODE_ALERT_CHANNEL:-notification}"
THRESHOLD_HOURS="${STUDIO_NODE_MONITOR_THRESHOLD_HOURS:-6}"
COOLDOWN_HOURS="${STUDIO_NODE_MONITOR_COOLDOWN_HOURS:-12}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/monitor-install.sh install
  scripts/monitor-install.sh uninstall
  scripts/monitor-install.sh status
  scripts/monitor-install.sh run

Environment:
  STUDIO_NODE_ALERT_CHANNEL=notification|slack|imessage|stdout|none
  STUDIO_NODE_ALERT_SLACK_WEBHOOK=https://hooks.slack.com/...
  STUDIO_NODE_ALERT_IMESSAGE_TO=person@example.com
  STUDIO_NODE_MONITOR_THRESHOLD_HOURS=6
  STUDIO_NODE_MONITOR_COOLDOWN_HOURS=12
USAGE
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

env_pair() {
  local key="$1" value="${2:-}"
  [ -n "$value" ] || return 0
  printf '    <key>%s</key>\n    <string>%s</string>\n' \
    "$key" "$(printf '%s' "$value" | xml_escape)"
}

install_agent() {
  mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_DIR}/node-monitor.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
$(env_pair STUDIO_NODE_ALERT_CHANNEL "$CHANNEL")
$(env_pair STUDIO_NODE_MONITOR_THRESHOLD_HOURS "$THRESHOLD_HOURS")
$(env_pair STUDIO_NODE_MONITOR_COOLDOWN_HOURS "$COOLDOWN_HOURS")
$(env_pair STUDIO_NODE_ALERT_SLACK_WEBHOOK "${STUDIO_NODE_ALERT_SLACK_WEBHOOK:-}")
$(env_pair STUDIO_NODE_ALERT_IMESSAGE_TO "${STUDIO_NODE_ALERT_IMESSAGE_TO:-}")
  </dict>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/node-monitor.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/node-monitor.err.log</string>
</dict>
</plist>
EOF
  chmod 644 "$PLIST"
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  launchctl kickstart -k "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
  printf 'installed %s\n' "$PLIST"
}

uninstall_agent() {
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  printf 'removed %s\n' "$PLIST"
}

status_agent() {
  if [ -r "$PLIST" ]; then
    printf 'plist: %s\n' "$PLIST"
  else
    printf 'plist: not installed\n'
  fi
  launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | sed -n '1,20p' || true
}

case "${1:-install}" in
  install|on) install_agent ;;
  uninstall|off|remove) uninstall_agent ;;
  status) status_agent ;;
  run) "$SCRIPT_DIR/node-monitor.sh" ;;
  --help|-h|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
