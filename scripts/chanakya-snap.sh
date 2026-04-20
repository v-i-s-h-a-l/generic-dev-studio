#!/usr/bin/env bash
# chanakya-snap.sh — regenerate a Chanakya snapshot file.
#
# Usage:
#   scripts/chanakya-snap.sh <domain>
#
# Domains (one per call):
#   briefs           Pending/briefed/in-progress task summary.
#   debt             Build + test debt counters.
#   feedback-inbox   Unprocessed feedback items.
#   events-tail      Last ~100 events from today's event log.
#
# Today this is a stub — it rewrites the skeleton with a fresh
# `generated_at` timestamp. Real population is a follow-up; mode packs
# already fall back to full-load when a snapshot is null / stale, so the
# stub is safe.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SNAP_DIR="$REPO_ROOT/chanakya/snapshots"

domain="${1:-}"
if [ -z "$domain" ]; then
  printf 'usage: chanakya-snap.sh <briefs|debt|feedback-inbox|events-tail>\n' >&2
  exit 2
fi

file="$SNAP_DIR/${domain}.json"
if [ ! -f "$file" ]; then
  printf 'chanakya-snap: unknown domain %s (no skeleton at %s)\n' "$domain" "$file" >&2
  exit 2
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)

# Stub: rewrite skeleton with fresh generated_at. Real producers land in
# follow-up commits; each domain will fill its own payload from the
# canonical source (master plan for briefs, counters file for debt,
# feedback-inbox/ dir for feedback, today's event log for events-tail).
case "$domain" in
  briefs)
    cat > "$tmp" <<JSON
{
  "generated_at": "$now",
  "schema": 1,
  "tasks": []
}
JSON
    ;;
  debt)
    cat > "$tmp" <<JSON
{
  "generated_at": "$now",
  "schema": 1,
  "build_debt": {"counter": 0, "threshold_warn": 6, "threshold_block": 12},
  "test_unit_debt": {"counter": 0, "threshold_warn": 4, "threshold_block": 8},
  "test_ui_debt": {"counter": 0, "threshold_warn": 3, "threshold_block": 6}
}
JSON
    ;;
  feedback-inbox)
    cat > "$tmp" <<JSON
{
  "generated_at": "$now",
  "schema": 1,
  "items": []
}
JSON
    ;;
  events-tail)
    cat > "$tmp" <<JSON
{
  "generated_at": "$now",
  "schema": 1,
  "events": []
}
JSON
    ;;
  *)
    printf 'chanakya-snap: unknown domain %s\n' "$domain" >&2
    rm -f "$tmp"
    exit 2
    ;;
esac

mv "$tmp" "$file"
printf 'wrote %s\n' "$file"
