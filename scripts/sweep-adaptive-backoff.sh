#!/usr/bin/env bash
# sweep-adaptive-backoff.sh <was-blank:0|1>
#
# Step 0G — computes the next auto-sweep delay using a multiplicative-backoff
# ladder. A "blank" sweep (no events, no debriefs, no reminders) doubles the
# current delay up to 7200s (120 min); any activity resets to 900s (15 min).
# Persists state in the per-project file returned by `resolve_auto_sweep_state`.
#
# Prints the next-delay-seconds to stdout so the caller (mode-pack Step 0G)
# can schedule accordingly.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

WAS_BLANK="${1:?usage: sweep-adaptive-backoff.sh <was-blank:0|1>}"
case "$WAS_BLANK" in
  0|1) ;;
  *) printf 'error: was-blank must be 0 or 1, got %s\n' "$WAS_BLANK" >&2; exit 2 ;;
esac

STATE=$(resolve_auto_sweep_state 2>/dev/null) || {
  printf 'error: cannot resolve auto-sweep state path\n' >&2; exit 2
}
mkdir -p "$(dirname "$STATE")" 2>/dev/null || true

MIN_DELAY=900
MAX_DELAY=7200

# Read current state. Missing file → treat as fresh (current_delay 900,
# consecutive_blank 0). Simple key:value parse — format is YAML-ish but not
# a full YAML doc, so grep/sed keeps the dependency surface small.
current_delay=""
consecutive_blank=""
if [ -f "$STATE" ]; then
  current_delay=$(awk -F': *' '/^current_delay_s:/ {print $2; exit}' "$STATE" 2>/dev/null)
  consecutive_blank=$(awk -F': *' '/^consecutive_blank:/ {print $2; exit}' "$STATE" 2>/dev/null)
fi
# Sanitize: strip whitespace, fall back to defaults.
current_delay=$(printf '%s' "${current_delay:-$MIN_DELAY}" | tr -d ' ')
consecutive_blank=$(printf '%s' "${consecutive_blank:-0}" | tr -d ' ')
case "$current_delay" in
  ''|*[!0-9]*) current_delay=$MIN_DELAY ;;
esac
case "$consecutive_blank" in
  ''|*[!0-9]*) consecutive_blank=0 ;;
esac

if [ "$WAS_BLANK" = "1" ]; then
  next_delay=$(( current_delay * 2 ))
  [ "$next_delay" -lt "$MIN_DELAY" ] && next_delay=$MIN_DELAY
  [ "$next_delay" -gt "$MAX_DELAY" ] && next_delay=$MAX_DELAY
  next_blank=$(( consecutive_blank + 1 ))
else
  next_delay=$MIN_DELAY
  next_blank=0
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp="$STATE.tmp.$$"
{
  printf 'current_delay_s: %s\n' "$next_delay"
  printf 'consecutive_blank: %s\n' "$next_blank"
  printf 'last_sweep_at: %s\n' "$now"
} > "$tmp" || { rm -f "$tmp"; exit 2; }
mv "$tmp" "$STATE" || { rm -f "$tmp"; exit 2; }

printf '%s\n' "$next_delay"
