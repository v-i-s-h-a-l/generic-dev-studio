#!/usr/bin/env bash
# node-monitor.sh — hourly always-on node monitor.
#
# Runs node-health.sh, tracks unreachable streaks in
# ~/.dev-studio/.runtime/node-monitor-state.json, and alerts after a node
# has been unreachable for the configured threshold. Disabled nodes are
# ignored by node-health output and by the persisted state.
#
# Configuration:
#   STUDIO_NODE_MONITOR_THRESHOLD_HOURS=6
#   STUDIO_NODE_MONITOR_COOLDOWN_HOURS=12
#   STUDIO_NODE_ALERT_CHANNEL=notification|slack|imessage|stdout|none
#   STUDIO_NODE_ALERT_SLACK_WEBHOOK=https://hooks.slack.com/...
#   STUDIO_NODE_ALERT_IMESSAGE_TO=person@example.com

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

STATE="$(resolve_runtime_global)/node-monitor-state.json"
THRESHOLD_HOURS="${STUDIO_NODE_MONITOR_THRESHOLD_HOURS:-6}"
COOLDOWN_HOURS="${STUDIO_NODE_MONITOR_COOLDOWN_HOURS:-12}"
CHANNEL="${STUDIO_NODE_ALERT_CHANNEL:-notification}"

command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }

now_epoch=$(date +%s)
threshold_s=$((THRESHOLD_HOURS * 3600))
cooldown_s=$((COOLDOWN_HOURS * 3600))
mkdir -p "$(dirname "$STATE")"
[ -r "$STATE" ] || printf '{"nodes":{}}\n' >"$STATE"

health_out=$("$SCRIPT_DIR/node-health.sh" 2>/dev/null)
health_rc=$?

json_escape() {
  jq -Rsa . <<<"${1:-}"
}

alert_send() {
  local node="$1" host="$2" streak="$3" hours="$4"
  local msg="Studio node ${node} (${host}) has been unreachable for ${hours}h (streak ${streak})."
  case "$CHANNEL" in
    none) return 0 ;;
    stdout) printf '%s\n' "$msg" ;;
    notification)
      if command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification $(json_escape "$msg") with title \"Studio node unreachable\"" >/dev/null 2>&1 || printf '%s\n' "$msg"
      else
        printf '%s\n' "$msg"
      fi
      ;;
    slack)
      if [ -n "${STUDIO_NODE_ALERT_SLACK_WEBHOOK:-}" ] && command -v curl >/dev/null 2>&1; then
        curl -fsS -X POST -H 'Content-Type: application/json' \
          --data "$(printf '{"text":%s}' "$(json_escape "$msg")")" \
          "$STUDIO_NODE_ALERT_SLACK_WEBHOOK" >/dev/null || printf '%s\n' "$msg"
      else
        printf 'warn: STUDIO_NODE_ALERT_SLACK_WEBHOOK missing; %s\n' "$msg" >&2
      fi
      ;;
    imessage)
      if [ -n "${STUDIO_NODE_ALERT_IMESSAGE_TO:-}" ] && command -v osascript >/dev/null 2>&1; then
        osascript <<OSA >/dev/null 2>&1 || printf '%s\n' "$msg"
tell application "Messages"
  send $(json_escape "$msg") to buddy "$STUDIO_NODE_ALERT_IMESSAGE_TO" of service "iMessage"
end tell
OSA
      else
        printf 'warn: STUDIO_NODE_ALERT_IMESSAGE_TO missing; %s\n' "$msg" >&2
      fi
      ;;
    *)
      printf 'warn: unknown STUDIO_NODE_ALERT_CHANNEL=%s; %s\n' "$CHANNEL" "$msg" >&2
      ;;
  esac
}

emit_unreachable_streak() {
  local node="$1" host="$2" streak="$3" hours="$4"
  command -v emit_event_keyed >/dev/null 2>&1 || return 0
  local data
  data=$(jq -cn --arg node "$node" --arg host "$host" \
    --argjson streak "$streak" --argjson hours "$hours" \
    '{"studio.dispatch.node":$node,"studio.dispatch.probe":"monitor","studio.dispatch.error":"unreachable_streak","studio.dispatch.streak_count":$streak,"studio.dispatch.unreachable_hours":$hours,host:$host}')
  emit_event_keyed studio dispatch node_unreachable "" "$data" \
    --idem-key "node-monitor:${node}:${streak}" >/dev/null 2>&1 || true
}

tmp_state=$(mktemp "${STATE}.XXXXXX") || exit 2
cp "$STATE" "$tmp_state"

seen_nodes=""
while IFS=$'\t' read -r id status load1 host; do
  [ -z "$id" ] && continue
  case "$status" in
    disabled|unknown) continue ;;
  esac
  seen_nodes="${seen_nodes}${id}
"
  if [ "$status" != "unreachable" ]; then
    tmp_next=$(mktemp "${STATE}.XXXXXX") || exit 2
    jq --arg id "$id" 'del(.nodes[$id])' "$tmp_state" >"$tmp_next" && mv "$tmp_next" "$tmp_state"
    continue
  fi

  first_seen=$(jq -r --arg id "$id" --argjson now "$now_epoch" '.nodes[$id].first_seen_epoch // $now' "$tmp_state")
  streak=$(jq -r --arg id "$id" '.nodes[$id].streak_count // 0' "$tmp_state")
  last_alert=$(jq -r --arg id "$id" '.nodes[$id].last_alert_epoch // 0' "$tmp_state")
  streak=$((streak + 1))
  elapsed=$((now_epoch - first_seen))
  hours=$((elapsed / 3600))
  should_alert=0
  if [ "$elapsed" -ge "$threshold_s" ] && [ "$((now_epoch - last_alert))" -ge "$cooldown_s" ]; then
    should_alert=1
    last_alert="$now_epoch"
  fi

  tmp_next=$(mktemp "${STATE}.XXXXXX") || exit 2
  jq --arg id "$id" --arg host "$host" \
    --argjson first "$first_seen" --argjson last "$last_alert" \
    --argjson streak "$streak" --argjson now "$now_epoch" \
    '.nodes[$id] = {host:$host, first_seen_epoch:$first, last_seen_epoch:$now, last_alert_epoch:$last, streak_count:$streak}' \
    "$tmp_state" >"$tmp_next" && mv "$tmp_next" "$tmp_state"

  if [ "$should_alert" = "1" ]; then
    alert_send "$id" "$host" "$streak" "$hours"
    emit_unreachable_streak "$id" "$host" "$streak" "$hours"
  fi
done <<EOF
$health_out
EOF

mv "$tmp_state" "$STATE"

exit "$health_rc"
