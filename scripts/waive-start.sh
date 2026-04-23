#!/usr/bin/env bash
# waive-start.sh <gate> <reason> [sunset_trigger]
#
# Creates a structured review-waive record for the current project at
# ~/.dev-studio/<project>/state/waives/<gate>.yaml. Fields:
#   gate, reason, started_at (UTC ISO-8601), sunset_trigger (free-text
#   predicate — when should we revisit?), accumulated_count (starts at 0).
#
# Idempotent: rewriting the file bumps `updated_at` but preserves
# `accumulated_count` so an in-flight waive isn't reset accidentally. To fully
# reset, run waive-lift.sh first.
#
# Exit codes:
#   0  ok
#   2  arg parse / resolution error

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

GATE="${1:-}"
REASON="${2:-}"
SUNSET="${3:-}"

if [ -z "$GATE" ] || [ -z "$REASON" ]; then
  printf 'usage: waive-start.sh <gate> <reason> [sunset_trigger]\n' >&2
  exit 2
fi

PROJECT=$(resolve_project 2>/dev/null) || { printf 'waive-start.sh: no project resolved\n' >&2; exit 2; }
F=$(resolve_waive_file_for "$PROJECT" "$GATE")
DIR=$(dirname "$F")
mkdir -p "$DIR" || { printf 'waive-start.sh: mkdir %s failed\n' "$DIR" >&2; exit 2; }

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COUNT=0
STARTED="$TS"
if [ -f "$F" ] && command -v yq >/dev/null 2>&1; then
  # Preserve accumulator + original start_at on re-invocation.
  prev_count=$(yq -r '.accumulated_count // 0' "$F" 2>/dev/null || echo 0)
  case "$prev_count" in ''|*[!0-9]*) prev_count=0 ;; esac
  COUNT="$prev_count"
  prev_started=$(yq -r '.started_at // ""' "$F" 2>/dev/null || echo "")
  [ -n "$prev_started" ] && STARTED="$prev_started"
fi

TMP="$F.tmp.$$"
{
  printf 'gate: %s\n' "$GATE"
  printf 'reason: %s\n' "$(printf '%s' "$REASON" | sed 's/"/\\"/g')"
  printf 'started_at: %s\n' "$STARTED"
  printf 'sunset_trigger: %s\n' "$(printf '%s' "$SUNSET" | sed 's/"/\\"/g')"
  printf 'accumulated_count: %s\n' "$COUNT"
  printf 'updated_at: %s\n' "$TS"
} > "$TMP" || { rm -f "$TMP"; exit 2; }
mv "$TMP" "$F" || { rm -f "$TMP"; exit 2; }

printf 'waive started: %s (gate=%s project=%s)\n' "$F" "$GATE" "$PROJECT"
