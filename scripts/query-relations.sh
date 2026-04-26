#!/usr/bin/env bash
# query-relations.sh — task relation graph view (forward + computed inverse).
#
# Usage:
#   scripts/query-relations.sh --task <id>
#   scripts/query-relations.sh --task <id> --format=json
#
# <id> may be either a UUIDv7 (matches task.id) or a legacy T<nnn>
# (matches task.legacy_task_id). Resolution scans plans/tasks/*.yaml.
#
# Output (default YAML):
#   id: <uuidv7>
#   legacy_id: T347
#   forward:
#     predecessors: [...]
#     parent: <uuid|null>
#     duplicate_of: <uuid|null>
#     similar_to: [...]
#     caused_by: [...]
#     reopen_chain: [...]
#   inverse:
#     blocks: [...]      # tasks where this id appears in predecessors
#     children: [...]    # tasks where this id is parent
#     duplicates: [...]  # tasks where this id is duplicate_of
#     causes: [...]      # tasks where this id appears in caused_by
#
# Each id in output is rendered as `<legacy>:<uuid>` when a legacy_task_id is
# known for the referenced task, otherwise `<uuid>`. This keeps human reads
# legible without losing UUID precision.
#
# No inverse field is persisted — the inverse view is recomputed at read time.
# SSOT lives on the forward edge in each task file.
#
# Compatible with bash 3.2 (macOS stock): no `declare -A`, no `mapfile`.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

PROJECT=""
TASK_ARG=""
FORMAT="yaml"

while [ $# -gt 0 ]; do
  case "$1" in
    --project)   PROJECT="${2:?--project requires slug}"; shift 2 ;;
    --task=*)    TASK_ARG="${1#--task=}"; shift ;;
    --task)      TASK_ARG="${2:?--task requires id}"; shift 2 ;;
    --format=*)  FORMAT="${1#--format=}"; shift ;;
    --format)    FORMAT="${2:?--format requires value}"; shift 2 ;;
    -h|--help)
      sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 2 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -z "$TASK_ARG" ]; then
  printf 'error: --task <id> is required\n' >&2
  exit 2
fi

if [ -z "$PROJECT" ]; then
  PROJECT=$(resolve_project 2>/dev/null) || {
    printf 'error: no project resolved. Pass --project <slug>.\n' >&2
    exit 2
  }
fi

if [ -n "${ACHILLES_PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$ACHILLES_PROJECT_ROOT"
else
  PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
fi

TASKS_DIR="$PROJECT_ROOT/plans/tasks"
if [ ! -d "$TASKS_DIR" ]; then
  printf 'error: tasks dir not found (%s)\n' "$TASKS_DIR" >&2
  exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
  printf 'error: yq (v4+) is required\n' >&2
  exit 2
fi

# Collect task files (deterministic order).
TASK_FILES_LIST=$(find "$TASKS_DIR" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null | sort)
if [ -z "$TASK_FILES_LIST" ]; then
  printf 'error: no task files in %s\n' "$TASKS_DIR" >&2
  exit 2
fi

# Pass 1: build parallel uuid/legacy/file arrays. Resolve target along the way.
ALL_UIDS=""     # newline-separated
ALL_LEGACIES="" # newline-separated, paired by line with ALL_UIDS
ALL_FILES=""    # newline-separated, paired by line
TARGET_UUID=""
TARGET_LEGACY=""
TARGET_FILE=""

while IFS= read -r f; do
  [ -z "$f" ] && continue
  uid=$(yq -r '.id // ""' "$f")
  legacy=$(yq -r '.legacy_task_id // ""' "$f")
  ALL_UIDS="$ALL_UIDS$uid"$'\n'
  ALL_LEGACIES="$ALL_LEGACIES$legacy"$'\n'
  ALL_FILES="$ALL_FILES$f"$'\n'
  if [ -z "$TARGET_UUID" ] && { [ "$uid" = "$TASK_ARG" ] || [ "$legacy" = "$TASK_ARG" ]; }; then
    TARGET_UUID="$uid"
    TARGET_LEGACY="$legacy"
    TARGET_FILE="$f"
  fi
done <<EOF
$TASK_FILES_LIST
EOF

if [ -z "$TARGET_UUID" ]; then
  printf 'error: no task matched id %s in %s\n' "$TASK_ARG" "$TASKS_DIR" >&2
  exit 1
fi

# Look up legacy id for a uuid via parallel-array scan. Empty input → empty out.
legacy_for() {
  local needle="$1"
  [ -z "$needle" ] && return 0
  local lineno=0 idx=0
  local found=""
  # Walk ALL_UIDS line-by-line; when we hit needle, return the same-index legacy.
  while IFS= read -r u; do
    idx=$((idx + 1))
    if [ "$u" = "$needle" ]; then
      lineno=$idx
      break
    fi
  done <<EOF
$ALL_UIDS
EOF
  [ "$lineno" -eq 0 ] && return 0
  idx=0
  while IFS= read -r l; do
    idx=$((idx + 1))
    if [ "$idx" = "$lineno" ]; then
      found="$l"
      break
    fi
  done <<EOF
$ALL_LEGACIES
EOF
  printf '%s' "$found"
}

prettify() {
  # arg: a uuid; prints "<legacy>:<uuid>" if legacy known, else "<uuid>".
  local uid="$1"
  [ -z "$uid" ] && return 0
  local legacy
  legacy=$(legacy_for "$uid")
  if [ -n "$legacy" ]; then
    printf '%s:%s' "$legacy" "$uid"
  else
    printf '%s' "$uid"
  fi
}

# Read forward edges from target file into newline-separated strings.
FW_PREDECESSORS=$(yq -r '.predecessors[]?' "$TARGET_FILE")
FW_PARENT=$(yq -r '.parent // ""' "$TARGET_FILE")
FW_DUP_OF=$(yq -r '.duplicate_of // ""' "$TARGET_FILE")
FW_SIMILAR=$(yq -r '.similar_to[]?' "$TARGET_FILE")
FW_CAUSED_BY=$(yq -r '.caused_by[]?' "$TARGET_FILE")
FW_REOPEN_CHAIN=$(yq -r '.reopen_chain[]?' "$TARGET_FILE")

# Compute inverse edges by scanning every task file.
INV_BLOCKS=""
INV_CHILDREN=""
INV_DUPLICATES=""
INV_CAUSES=""

while IFS= read -r f; do
  [ -z "$f" ] && continue
  uid=$(yq -r '.id // ""' "$f")
  [ "$uid" = "$TARGET_UUID" ] && continue
  [ -z "$uid" ] && continue

  if yq -e ".predecessors[]? | select(. == \"$TARGET_UUID\")" "$f" >/dev/null 2>&1; then
    INV_BLOCKS="$INV_BLOCKS$uid"$'\n'
  fi
  parent=$(yq -r '.parent // ""' "$f")
  [ "$parent" = "$TARGET_UUID" ] && INV_CHILDREN="$INV_CHILDREN$uid"$'\n'
  dup=$(yq -r '.duplicate_of // ""' "$f")
  [ "$dup" = "$TARGET_UUID" ] && INV_DUPLICATES="$INV_DUPLICATES$uid"$'\n'
  if yq -e ".caused_by[]? | select(. == \"$TARGET_UUID\")" "$f" >/dev/null 2>&1; then
    INV_CAUSES="$INV_CAUSES$uid"$'\n'
  fi
done <<EOF
$TASK_FILES_LIST
EOF

emit_yaml_array() {
  local key="$1" data="$2"
  # Strip empty lines.
  local non_empty
  non_empty=$(printf '%s' "$data" | awk 'NF')
  if [ -z "$non_empty" ]; then
    printf '  %s: []\n' "$key"
    return
  fi
  printf '  %s:\n' "$key"
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    printf '    - %s\n' "$(prettify "$v")"
  done <<EOF
$non_empty
EOF
}

emit_yaml_scalar() {
  local key="$1" val="$2"
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    printf '  %s: null\n' "$key"
  else
    printf '  %s: %s\n' "$key" "$(prettify "$val")"
  fi
}

if [ "$FORMAT" = "json" ]; then
  # Convert each newline-separated edge list to a JSON array.
  to_json_array() {
    printf '%s' "$1" | awk 'NF' | jq -R . | jq -s '.'
  }
  preds_json=$(to_json_array "$FW_PREDECESSORS")
  sim_json=$(to_json_array "$FW_SIMILAR")
  caused_json=$(to_json_array "$FW_CAUSED_BY")
  reopen_json=$(to_json_array "$FW_REOPEN_CHAIN")
  blocks_json=$(to_json_array "$INV_BLOCKS")
  children_json=$(to_json_array "$INV_CHILDREN")
  duplicates_json=$(to_json_array "$INV_DUPLICATES")
  causes_json=$(to_json_array "$INV_CAUSES")
  jq -n \
    --arg id "$TARGET_UUID" \
    --arg legacy "$TARGET_LEGACY" \
    --arg parent "$FW_PARENT" \
    --arg dup_of "$FW_DUP_OF" \
    --argjson preds "$preds_json" \
    --argjson sim "$sim_json" \
    --argjson caused "$caused_json" \
    --argjson reopen "$reopen_json" \
    --argjson blocks "$blocks_json" \
    --argjson children "$children_json" \
    --argjson duplicates "$duplicates_json" \
    --argjson causes "$causes_json" \
    '{
      id: $id,
      legacy_id: (if $legacy == "" then null else $legacy end),
      forward: {
        predecessors: $preds,
        parent: (if $parent == "" then null else $parent end),
        duplicate_of: (if $dup_of == "" then null else $dup_of end),
        similar_to: $sim,
        caused_by: $caused,
        reopen_chain: $reopen
      },
      inverse: {
        blocks: $blocks,
        children: $children,
        duplicates: $duplicates,
        causes: $causes
      }
    }'
  exit 0
fi

# Default YAML output.
printf 'id: %s\n' "$TARGET_UUID"
if [ -n "$TARGET_LEGACY" ]; then
  printf 'legacy_id: %s\n' "$TARGET_LEGACY"
else
  printf 'legacy_id: null\n'
fi
printf 'forward:\n'
emit_yaml_array predecessors "$FW_PREDECESSORS"
emit_yaml_scalar parent "$FW_PARENT"
emit_yaml_scalar duplicate_of "$FW_DUP_OF"
emit_yaml_array similar_to "$FW_SIMILAR"
emit_yaml_array caused_by "$FW_CAUSED_BY"
emit_yaml_array reopen_chain "$FW_REOPEN_CHAIN"
printf 'inverse:\n'
emit_yaml_array blocks "$INV_BLOCKS"
emit_yaml_array children "$INV_CHILDREN"
emit_yaml_array duplicates "$INV_DUPLICATES"
emit_yaml_array causes "$INV_CAUSES"
