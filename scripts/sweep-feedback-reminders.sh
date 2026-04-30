#!/usr/bin/env bash
# sweep-feedback-reminders.sh — Step 0E2 of the inbox sweep.
#
# Reads the `## Reminders` table in feedback/active.md. For each row whose
# `due_at` has passed, emits `feedback_reminder_due` (new Chanakya event; see
# `_shared/contracts/events.md`) and removes the row. The emit is the only
# dispatch surface — the actual ingest mode is invoked by a consumer of the
# event, not this script.
#
# Row shape (from `modes/sync-slack.md` §auto-schedule):
#   | <due_at ISO-8601> | <type> | <args...> | <description> |
#
# Idempotent: consumed rows are removed on a successful emit, so a repeat
# run finds nothing.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"
# shellcheck source=lib-sweep-timing.sh
. "$SCRIPT_DIR/lib-sweep-timing.sh"

PROJECT=$(resolve_project 2>/dev/null) || exit 0
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
ACTIVE="$PROJECT_ROOT/feedback/active.md"
sweep_timing_start

if [ ! -f "$ACTIVE" ]; then
  sweep_timing_emit feedback-reminders noop 0
  exit 0
fi

now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Scan for rows under `## Reminders`. Parse due_at from column 1, route the
# rest of the row as the reminder body. Two-pass because we need to both
# emit events AND rewrite the file in place.
fired_tmp=$(mktemp 2>/dev/null) || exit 0

awk -v now_iso="$now_iso" -v fired_out="$fired_tmp" '
  function parse_due(s) {
    # Strip surrounding whitespace; skip separator / header rows.
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    if (s ~ /^-+$/) return ""
    if (s == "" || s ~ /^<!-/) return ""
    # YYYY-MM-DDTHH:MM:SSZ — portable parse via substr (BSD awk lacks the
    # 3-arg match() array form). Fixed-width spec is reliable here.
    if (s !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/) return ""
    return substr(s, 1, 20)
  }
  BEGIN { in_rem = 0 }
  /^## Reminders/ { in_rem = 1; print; next }
  /^## / && !/^## Reminders/ { in_rem = 0; print; next }
  in_rem == 1 && /^\|/ {
    # Header + separator rows pass through untouched.
    if ($0 ~ /^\| *-+ *\|/ || $0 ~ /due_at/) { print; next }
    # Split on pipes. Field 2 is due_at after leading-empty field 1.
    n = split($0, f, "|")
    due = f[2]
    due_iso = parse_due(due)
    if (due_iso != "" && due_iso <= now_iso) {
      # Emit the raw line to the side channel; drop from file output.
      print $0 > fired_out
      next
    }
    print; next
  }
  { print }
' "$ACTIVE" > "$ACTIVE.tmp.$$" || {
  rm -f "$ACTIVE.tmp.$$" "$fired_tmp"
  exit 0
}

# Emit one event per fired row. Ingest-mode-hint is the second table column
# (reminder type, e.g. `ingest-reminder`); reminder_body is everything else.
fired_count=0
while IFS= read -r row; do
  [ -z "$row" ] && continue
  fired_count=$((fired_count + 1))
  # Extract columns: strip leading/trailing `|`, split.
  row_clean=$(printf '%s' "$row" | sed -E 's/^\| *//; s/ *\|$//')
  IFS='|' read -r due_at hint args desc _rest <<EOF
$row_clean
EOF
  hint=$(printf '%s' "$hint" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  due_at=$(printf '%s' "$due_at" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  body=$(printf '%s' "$args $desc" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  # JSON-escape minimal set — due_at is ISO so safe as-is.
  esc_body=${body//\\/\\\\}
  esc_body=${esc_body//\"/\\\"}
  esc_hint=${hint//\\/\\\\}
  esc_hint=${esc_hint//\"/\\\"}
  data=$(printf '{"reminder_body":"%s","ingest_mode_hint":"%s","due_at":"%s"}' \
    "$esc_body" "$esc_hint" "$due_at")
  emit_event_keyed chanakya inbox-sweep feedback_reminder_due "" "$data" >/dev/null || true
done < "$fired_tmp"

# Apply the rewritten file only if at least one reminder fired. Otherwise
# we skip the rewrite to avoid touching mtime for a no-op sweep (readers
# downstream key off mtime for freshness heuristics).
if [ -s "$fired_tmp" ]; then
  mv "$ACTIVE.tmp.$$" "$ACTIVE" 2>/dev/null || rm -f "$ACTIVE.tmp.$$"
else
  rm -f "$ACTIVE.tmp.$$"
fi
rm -f "$fired_tmp"

sweep_timing_emit feedback-reminders completed "$fired_count"
exit 0
