#!/usr/bin/env bash
# schedule-worker-sync.sh — install / uninstall / status the launchd agent
# that runs sync-workers-all.sh on a periodic schedule.
#
# Lives entirely on the MANAGER. Workers stay passive per the architecture.
#
# Usage
#   scripts/schedule-worker-sync.sh --install [--interval daily|weekly|hourly]
#   scripts/schedule-worker-sync.sh --uninstall
#   scripts/schedule-worker-sync.sh --status
#   scripts/schedule-worker-sync.sh --run-now      # one-shot: invoke sync-workers-all
#
# The launchd agent runs as YOUR user (not root). It tees output to
# ~/.dev-studio/.runtime/logs/worker-sync-<ts>.log so you can audit what
# happened overnight without scrubbing Console.app.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

LABEL="dev.studio.worker-sync"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/.dev-studio/.runtime/logs"

ACTION=""
INTERVAL="daily"

while [ $# -gt 0 ]; do
  case "$1" in
    --install)   ACTION="install"; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --status)    ACTION="status"; shift ;;
    --run-now)   ACTION="run-now"; shift ;;
    --interval)  INTERVAL="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'error: unknown flag: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -z "$ACTION" ] && { printf 'error: pick one of --install / --uninstall / --status / --run-now\n' >&2; exit 1; }

case "$INTERVAL" in
  hourly)  INTERVAL_SECONDS=3600 ;;
  daily)   INTERVAL_SECONDS=86400 ;;
  weekly)  INTERVAL_SECONDS=604800 ;;
  *) printf 'error: --interval must be hourly|daily|weekly (got %s)\n' "$INTERVAL" >&2; exit 1 ;;
esac

case "$ACTION" in
  install)
    mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_DIR}/sync-workers-all.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>${INTERVAL_SECONDS}</integer>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/worker-sync.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/worker-sync.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST
    # bootstrap the agent. macOS's launchctl bootstrap takes a domain target;
    # the modern incantation is `bootstrap gui/<uid>` so the agent runs as
    # the logged-in user without root.
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
      || launchctl load "$PLIST"
    printf 'installed: %s (interval=%s)\n' "$LABEL" "$INTERVAL"
    printf 'logs: %s/worker-sync.{out,err}.log\n' "$LOG_DIR"
    printf 'first run will fire in ≤ %s\n' "$INTERVAL"
    ;;

  uninstall)
    if [ -f "$PLIST" ]; then
      launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null \
        || launchctl unload "$PLIST" 2>/dev/null \
        || true
      rm -f "$PLIST"
      printf 'uninstalled: %s\n' "$LABEL"
    else
      printf '%s not installed (nothing to remove)\n' "$LABEL"
    fi
    ;;

  status)
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      printf '%s: ACTIVE\n' "$LABEL"
      launchctl print "gui/$(id -u)/$LABEL" | grep -E 'state|last exit code|run count|interval' || true
      [ -f "$LOG_DIR/worker-sync.out.log" ] && printf '\nlatest stdout (tail):\n' && tail -n 20 "$LOG_DIR/worker-sync.out.log"
    else
      printf '%s: NOT INSTALLED\n' "$LABEL"
    fi
    ;;

  run-now)
    "$SCRIPT_DIR/sync-workers-all.sh"
    ;;
esac
