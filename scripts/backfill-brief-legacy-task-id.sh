#!/usr/bin/env bash
# backfill-brief-legacy-task-id.sh — patch briefs missing legacy_task_id (#296).
#
# Scans all briefs under plans/briefs/. For each brief that has a task_id
# but no legacy_task_id, looks up the parent task's legacy_task_id and
# patches the brief YAML in-place via yq.
#
# Usage:
#   scripts/backfill-brief-legacy-task-id.sh [--dry-run]
#
# Exit: 0 on success (including no-op). 1 on errors. 2 on bad args.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'backfill-brief-legacy-task-id: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v yq >/dev/null 2>&1 || { printf 'error: yq required\n' >&2; exit 1; }

PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 1; }
BRIEFS_DIR=$(resolve_briefs_dir_for "$PROJECT")
TASKS_DIR=$(resolve_tasks_dir_for "$PROJECT")

[ -d "$BRIEFS_DIR" ] || { printf 'no briefs dir at %s\n' "$BRIEFS_DIR" >&2; exit 0; }
[ -d "$TASKS_DIR" ] || { printf 'no tasks dir at %s\n' "$TASKS_DIR" >&2; exit 0; }

PATCHED=0
SKIPPED=0
ERRORS=0

for brief in "$BRIEFS_DIR"/*.yaml; do
  [ -r "$brief" ] || continue

  existing_ltid=$(yq -r '.legacy_task_id // ""' "$brief" 2>/dev/null || echo "")
  [ -n "$existing_ltid" ] && continue

  task_uuid=$(yq -r '.task_id // ""' "$brief" 2>/dev/null || echo "")
  [ -z "$task_uuid" ] && continue

  task_file="$TASKS_DIR/${task_uuid}.yaml"
  if [ ! -r "$task_file" ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  task_ltid=$(yq -r '.legacy_task_id // ""' "$task_file" 2>/dev/null || echo "")
  if [ -z "$task_ltid" ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  brief_id=$(basename "$brief" .yaml)
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] would patch %s → legacy_task_id: "%s"\n' "$brief_id" "$task_ltid"
  else
    if yq -i ".legacy_task_id = \"$task_ltid\"" "$brief" 2>/dev/null; then
      printf 'patched %s → legacy_task_id: "%s"\n' "$brief_id" "$task_ltid"
      PATCHED=$((PATCHED + 1))
    else
      printf 'ERROR patching %s\n' "$brief_id" >&2
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

printf '\nDone. patched=%d skipped=%d errors=%d\n' "$PATCHED" "$SKIPPED" "$ERRORS"
[ "$ERRORS" -gt 0 ] && exit 1
exit 0
