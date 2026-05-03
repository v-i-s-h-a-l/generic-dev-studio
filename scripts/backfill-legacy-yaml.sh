#!/usr/bin/env bash
# backfill-legacy-yaml.sh — one-shot YAML backfill for pre-2026-04-17 legacy tasks.
#
# Mints YAML task + brief artifacts for every legacy-markdown-only task that has
# a matching debrief in the legacy archive. Stops legacy_artifact_read noise.
# Resolves issue #246 / closes #109.
#
# Why these tasks were skipped by migrate-ledger.sh: they pre-date the 2026-04-17
# dual-write fix, so no paired YAML exists. Every /achilles <task-id> dispatch on
# them trips task-load-spec.sh's diagnostic legacy path (when explicitly enabled)
# and emits legacy_artifact_read. After backfill, task-load-spec.sh finds the YAML
# brief (state=draft) before any legacy inspection is needed. The terminal-state
# guard then blocks re-dispatch because the task state is archived.
#
# Conservative: if no debrief exists for a task, skip it (may be in-flight).
# Idempotent:   if a YAML task or brief with matching legacy_task_id exists, skip.
#
# Usage:
#   scripts/backfill-legacy-yaml.sh [--project <slug>]           # dry-run (default)
#   scripts/backfill-legacy-yaml.sh --apply [--project <slug>]   # write YAML
#   scripts/backfill-legacy-yaml.sh --help
#
# Exit codes:
#   0   success
#   1   missing dependency (yq)
#   2   project resolution error

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

APPLY=0
PROJECT_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)           APPLY=1; shift ;;
    --dry-run)         APPLY=0; shift ;;
    --project)         PROJECT_OVERRIDE="${2:?--project requires <slug>}"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf 'backfill-legacy-yaml.sh: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

if ! command -v yq >/dev/null 2>&1; then
  printf 'backfill-legacy-yaml: yq is required (brew install yq)\n' >&2
  exit 1
fi

if [ "$APPLY" = "0" ]; then
  DRY_RUN=1
  export DRY_RUN
fi

if [ -n "$PROJECT_OVERRIDE" ]; then
  ACHILLES_PROJECT="$PROJECT_OVERRIDE"
  export ACHILLES_PROJECT
fi

PROJECT=$(resolve_project 2>/dev/null) || {
  printf 'backfill-legacy-yaml: no project resolved. Set ACHILLES_PROJECT or run from a git repo.\n' >&2
  exit 2
}

LEGACY_TASKS_DIR="$(resolve_plans_dir_for "$PROJECT")/.legacy-archive/chanakya-tasks"
LEGACY_DEBRIEFS_DIR="$(resolve_plans_dir_for "$PROJECT")/.legacy-archive/chanakya-inbox/processed"
TASKS_DIR=$(resolve_tasks_dir_for "$PROJECT")
BRIEFS_DIR=$(resolve_briefs_dir_for "$PROJECT")
DEBRIEFS_DIR=$(resolve_debriefs_dir_for "$PROJECT")

if [ ! -d "$LEGACY_TASKS_DIR" ]; then
  printf 'backfill-legacy-yaml: no legacy tasks dir at %s (nothing to do)\n' "$LEGACY_TASKS_DIR" >&2
  exit 0
fi

printf 'backfill-legacy-yaml: project=%s mode=%s\n' "$PROJECT" \
  "$([ "$APPLY" = "1" ] && echo apply || echo dry-run)" >&2

# ---------- Debrief existence check ----------
#
# Returns 0 if any debrief evidence exists for <task_id>:
#   1. Legacy markdown in plans/.legacy-archive/chanakya-inbox/processed/
#   2. YAML debrief in plans/debriefs/ carrying legacy_task_id field
#
_debrief_exists_for() {
  local tid="$1"

  if [ -d "$LEGACY_DEBRIEFS_DIR" ]; then
    # Fast path: filename starts with the task ID (T009-debrief.md, etc.).
    if ls "$LEGACY_DEBRIEFS_DIR/${tid}"-*.md "$LEGACY_DEBRIEFS_DIR/${tid}.md" \
        2>/dev/null | grep -q .; then
      return 0
    fi
    # Bundle filenames containing the task ID (T002-T003-debrief.md for T003).
    if ls "$LEGACY_DEBRIEFS_DIR"/*.md 2>/dev/null | grep -q "$tid"; then
      return 0
    fi
    # Slow path: task ID in debrief body (e.g., T001-T008 bundles).
    if grep -rl "\b${tid}\b" "$LEGACY_DEBRIEFS_DIR"/*.md 2>/dev/null \
        | head -1 | grep -q .; then
      return 0
    fi
  fi

  # YAML debrief surface.
  if [ -d "$DEBRIEFS_DIR" ]; then
    if find "$DEBRIEFS_DIR" -name "*.yaml" \
        -exec grep -l "^legacy_task_id: \"${tid}\"$" {} \; 2>/dev/null \
        | grep -q .; then
      return 0
    fi
  fi

  return 1
}

# ---------- Field extractor ----------
#
# Extracts the first word of a named field from legacy brief markdown.
# Handles "- **FIELD:** VALUE" and plain "FIELD: VALUE" formats.
# Uses sed for the bold-label strip because macOS BSD awk does not reliably
# treat \* as a literal asterisk in regex.
_extract_field() {
  local f="$1" field="$2"
  local val
  val=$(grep -m1 "\*\*${field}:\*\*" "$f" 2>/dev/null \
    | sed 's/^[^*]*[*][*][^:]*:[*][*][[:space:]]*//' \
    | awk '{print $1}')
  if [ -z "$val" ]; then
    val=$(grep -m1 "^${field}:[[:space:]]" "$f" 2>/dev/null \
      | sed "s/^${field}:[[:space:]]*//" \
      | awk '{print $1}')
  fi
  printf '%s' "$val"
}

# Maps Complexity/Size field values to xs|s|m|l. Defaults to m.
_parse_size() {
  local f="$1" raw
  raw=$(_extract_field "$f" "Size")
  [ -z "$raw" ] && raw=$(_extract_field "$f" "Complexity")
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d ' \t' | head -c 4)
  case "${raw:-}" in
    xs)            printf 'xs' ;;
    s|small)       printf 's' ;;
    l|large|xl)    printf 'l' ;;
    *)             printf 'm' ;;
  esac
}

# Reads **Type:** and normalises to the brief type enum. Defaults to feature.
_parse_type() {
  local f="$1" raw
  raw=$(_extract_field "$f" "Type" | tr '[:upper:]' '[:lower:]' | tr -d ' \t' | head -c 32)
  case "${raw:-}" in
    bugfix|bug)    printf 'bugfix' ;;
    refactor)      printf 'refactor' ;;
    polish)        printf 'polish' ;;
    chore)         printf 'chore' ;;
    docs)          printf 'docs' ;;
    *)             printf 'feature' ;;
  esac
}

# Reads **Priority:** and validates against P0-P4. Defaults to P2.
_parse_priority() {
  local f="$1" raw
  raw=$(_extract_field "$f" "Priority" | tr '[:lower:]' '[:upper:]' | tr -d ' \t' | head -c 4)
  case "${raw:-}" in
    P0|P1|P2|P3|P4) printf '%s' "$raw" ;;
    *)               printf 'P2' ;;
  esac
}

# ---------- Section parser ----------
#
# Prints "TASK_ID<TAB>TITLE" for every Task Brief section in <file>.
# Handles three formats in the legacy archive:
#   A. Single:    "# Task Brief: T009 — Title"
#   B. Plus-bundle: "# Task Brief: T023 + T024 + T025 — Title" (shared title)
#   C. Multi-section: multiple "# Task Brief: T<id> — Title" lines (own titles)
_parse_task_sections() {
  local f="$1"
  grep "^# Task Brief:" "$f" 2>/dev/null | while IFS= read -r line; do
    local rest id_part title
    rest="${line#\# Task Brief: }"
    if printf '%s' "$rest" | grep -q ' — '; then
      id_part=$(printf '%s' "$rest" | sed 's/ — .*//')
      title=$(printf '%s' "$rest" | sed 's/^[^—]*— //')
    elif printf '%s' "$rest" | grep -q ' - '; then
      id_part=$(printf '%s' "$rest" | sed 's/ - .*//')
      title=$(printf '%s' "$rest" | sed 's/^[^-]*- //')
    else
      id_part="$rest"
      title="(no title)"
    fi
    # Split bundle IDs on "+" or "," and emit one row per valid task ID.
    # printf '%s\n' ensures trailing newline so `while read` picks up last token.
    printf '%s\n' "$id_part" | tr '+' '\n' | tr ',' '\n' | sed 's/[[:space:]]//g' \
      | while IFS= read -r tid; do
          [ -z "$tid" ] && continue
          printf '%s' "$tid" | grep -qE '^T[0-9]+[a-z]?$' || continue
          printf '%s\t%s\n' "$tid" "$title"
        done
  done
}

# ---------- Main loop ----------

skipped_exists=0
skipped_no_debrief=0
written=0
errors=0

# Hold index rebuild until the end — one flush covers all artifact writes.
WITHHOLD_INDEX=1
export WITHHOLD_INDEX

# Pre-resolve project root so _artifact_path doesn't re-fork per artifact.
LEDGER_PROJECT_ROOT="$(resolve_project_root_for "$PROJECT")"
export LEDGER_PROJECT_ROOT

shopt -s nullglob
for brief_md in "$LEGACY_TASKS_DIR"/*.md; do
  [ -f "$brief_md" ] || continue

  size=$(_parse_size "$brief_md")
  type=$(_parse_type "$brief_md")
  priority=$(_parse_priority "$brief_md")

  while IFS=$'\t' read -r tid title; do
    [ -z "$tid" ] && continue

    # Idempotency: skip if a YAML task already carries this legacy ID.
    if [ -d "$TASKS_DIR" ] \
        && ls "$TASKS_DIR"/*.yaml 2>/dev/null | head -1 | grep -q . \
        && grep -l "^legacy_task_id: \"${tid}\"$" "$TASKS_DIR"/*.yaml 2>/dev/null \
           | head -1 | grep -q .; then
      skipped_exists=$((skipped_exists + 1))
      printf '  skip (task exists):  %s\n' "$tid" >&2
      continue
    fi

    # Idempotency: skip if a YAML brief already carries this legacy ID.
    # A brief alone already stops task-load-spec.sh from reaching the
    # diagnostic legacy path.
    if [ -d "$BRIEFS_DIR" ] \
        && ls "$BRIEFS_DIR"/*.yaml 2>/dev/null | head -1 | grep -q . \
        && grep -l "^legacy_task_id: \"${tid}\"$" "$BRIEFS_DIR"/*.yaml 2>/dev/null \
           | head -1 | grep -q .; then
      skipped_exists=$((skipped_exists + 1))
      printf '  skip (brief exists): %s\n' "$tid" >&2
      continue
    fi

    # Conservative: skip if no debrief evidence (task may be in-flight).
    if ! _debrief_exists_for "$tid"; then
      skipped_no_debrief=$((skipped_no_debrief + 1))
      printf '  skip (no debrief):   %s  %s\n' "$tid" "$title" >&2
      continue
    fi

    printf '  %s %s  size=%s type=%s priority=%s  %s\n' \
      "$([ "$APPLY" = "1" ] && echo "WRITE" || echo "would-write")" \
      "$tid" "$size" "$type" "$priority" "$title"

    if [ "$APPLY" = "1" ]; then
      task_uuid=$(mint_uuidv7)
      brief_uuid=$(mint_uuidv7)

      if ! write_task_artifact "$task_uuid" "archived" "$title" \
          "legacy_task_id=${tid}" "priority=${priority}" 2>&1; then
        printf '  ERROR: write_task_artifact failed for %s\n' "$tid" >&2
        errors=$((errors + 1))
        continue
      fi

      if ! write_brief_artifact "$brief_uuid" "$task_uuid" "$type" "$size" \
          "awaiting_user=false" \
          "legacy_task_id=${tid}" "body_file=${brief_md}" 2>&1; then
        printf '  ERROR: write_brief_artifact failed for %s\n' "$tid" >&2
        errors=$((errors + 1))
        continue
      fi

      # Link task → brief; best-effort (non-fatal if artifact not yet on disk).
      set_task_link "$task_uuid" "brief" "$brief_uuid" 2>/dev/null || true

      emit_event_keyed chanakya backfill legacy_backfill_written "$tid" \
        "$(printf '{"legacy_task_id":"%s","task_uuid":"%s","brief_uuid":"%s","source_md":"%s"}' \
          "$tid" "$task_uuid" "$brief_uuid" "$(basename "$brief_md")")" \
        >/dev/null 2>&1 || true

      written=$((written + 1))
    else
      written=$((written + 1))
    fi
  done < <(_parse_task_sections "$brief_md")
done
shopt -u nullglob

# One index rebuild for all written artifacts.
if [ "$APPLY" = "1" ] && [ "$written" -gt 0 ]; then
  WITHHOLD_INDEX=0
  flush_index
fi

printf '\nbackfill-legacy-yaml: %s=%d  skipped_exists=%d  skipped_no_debrief=%d  errors=%d\n' \
  "$([ "$APPLY" = "1" ] && echo written || echo would_write)" \
  "$written" "$skipped_exists" "$skipped_no_debrief" "$errors" >&2

if [ "$APPLY" = "0" ] && [ "$written" -gt 0 ]; then
  printf 'Re-run with --apply to write %d artifact pair(s).\n' "$written" >&2
fi

[ "$errors" -eq 0 ]
