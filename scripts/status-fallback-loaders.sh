#!/usr/bin/env bash
# status-fallback-loaders.sh — full-load per-domain when a snapshot misses.
#
# Sub-commands produce the same JSON payload shape the snapshot would have
# produced, so the status mode pack can treat hit + fallback uniformly.
#
# Usage:
#   scripts/status-fallback-loaders.sh <briefs|debt|feedback|events-tail>
#
# Exits 0 on success (JSON on stdout). Exit 2 on unknown subcommand or fatal
# resolution error.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

cmd="${1:-}"
case "$cmd" in
  briefs|debt|feedback|events-tail) ;;
  "") printf 'usage: status-fallback-loaders.sh <briefs|debt|feedback|events-tail>\n' >&2; exit 2 ;;
  *)  printf 'unknown subcommand: %s\n' "$cmd" >&2; exit 2 ;;
esac

PROJECT=$(resolve_project 2>/dev/null) || exit 2
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")

load_briefs() {
  # Prefer post-migration query-plans.sh (authoritative). Legacy parser is the
  # Phase 2.6 transition fallback.
  local tasks
  if tasks=$("$SCRIPT_DIR/query-plans.sh" --kind=task 2>/dev/null) && [ -n "$tasks" ]; then
    printf '%s\n' "$tasks"
    return 0
  fi
  local master="$PROJECT_ROOT/plans/chanakya-master.md"
  if [ ! -f "$master" ]; then
    printf '{"tasks":[],"total":0,"source":"empty"}\n'
    return 0
  fi
  # Emit one legacy_artifact_read per sweep per domain — observable.
  append_event chanakya legacy_artifact_read "" \
    '{"domain":"briefs","reason":"plans_index_missing","caller":"status-fallback-loaders"}' \
    2>/dev/null || true
  # Use the same awk that scripts/chanakya-snap.sh produce_briefs uses — keep the
  # two paths in sync by delegating. chanakya-snap's `briefs` subcommand writes
  # to the snapshot file; we need the same payload on stdout.
  local snap_file="$PROJECT_ROOT/.runtime/state/chanakya-snapshots/briefs.json"
  "$SCRIPT_DIR/chanakya-snap.sh" briefs >/dev/null 2>&1
  if [ -f "$snap_file" ]; then
    cat "$snap_file"
  else
    printf '{"tasks":[],"total":0,"source":"legacy_fallback_unavailable"}\n'
  fi
}

load_debt() {
  local snap_file="$PROJECT_ROOT/.runtime/state/chanakya-snapshots/debt.json"
  "$SCRIPT_DIR/chanakya-snap.sh" debt >/dev/null 2>&1
  if [ -f "$snap_file" ]; then
    cat "$snap_file"
  else
    printf '{"build":{"counter":0,"threshold":6},"test_unit":{"counter":0},"test_ui":{"counter":0},"source":"empty"}\n'
  fi
}

load_feedback() {
  local snap_file="$PROJECT_ROOT/.runtime/state/chanakya-snapshots/feedback-inbox.json"
  "$SCRIPT_DIR/chanakya-snap.sh" feedback-inbox >/dev/null 2>&1
  if [ -f "$snap_file" ]; then
    cat "$snap_file"
  else
    printf '{"total_pending":0,"by_scope":{},"source":"empty"}\n'
  fi
}

load_events_tail() {
  local log
  log=$(resolve_event_log) || { printf '{"events":[]}\n'; return 0; }
  if [ ! -f "$log" ]; then
    printf '{"events":[]}\n'
    return 0
  fi
  # Last 25 events. jq -s reads as array; slice to tail.
  local lines
  lines=$(tail -n 25 "$log" 2>/dev/null | jq -s '.' 2>/dev/null) || lines='[]'
  printf '{"events":%s}\n' "$lines"
}

case "$cmd" in
  briefs)       load_briefs ;;
  debt)         load_debt ;;
  feedback)     load_feedback ;;
  events-tail)  load_events_tail ;;
esac
