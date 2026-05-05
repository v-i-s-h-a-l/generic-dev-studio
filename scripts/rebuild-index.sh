#!/usr/bin/env bash
# rebuild-index.sh — regenerate plans/index.yaml from the per-artifact YAML
# files under plans/*/. Authoritative output is the hybrid relational index
# per §4 of PHASE-2-6-PLAN.md.
#
# Usage:
#   scripts/rebuild-index.sh                       # writes to canonical path
#   scripts/rebuild-index.sh --project <slug>      # target a specific project
#   scripts/rebuild-index.sh --stdout              # print, do not write
#   scripts/rebuild-index.sh --validate            # regenerate + exit 1 on
#                                                    drift (pre-commit hook)
#
# The index is authoritative for joins across artifact kinds. Individual
# artifact files carry back-references (`links:` blocks) that must stay
# consistent; `scripts/validate-plans-index.sh` (ships alongside) checks
# the invariants from `_shared/contracts/plans-index-validator.md`.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

PROJECT=""
MODE="write"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)   PROJECT="${2:?--project requires slug}"; shift 2 ;;
    --stdout)    MODE="stdout"; shift ;;
    --validate)  MODE="validate"; shift ;;
    -h|--help)
      sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 2 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

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

PLANS_DIR="$PROJECT_ROOT/plans"
INDEX_PATH="$PLANS_DIR/index.yaml"

if [ ! -d "$PLANS_DIR" ]; then
  printf 'error: plans dir not found: %s\n' "$PLANS_DIR" >&2
  exit 2
fi

# Extract a top-level YAML scalar value from the artifact. Keeps quoting
# stable (we emit quoted values verbatim back out) and tolerates `null`.
# Returns empty string for missing keys.
yaml_scalar() {
  local file="$1" key="$2"
  # Skip keys inside nested mapping blocks — only match column-0 keys. Also
  # skip multi-line body: | blocks by bailing on hitting `body: |`.
  awk -v k="$key" '
    /^[[:space:]]/ { next }
    /^body:[[:space:]]*\|[[:space:]]*$/ { exit }
    $0 ~ "^" k ":[[:space:]]*" {
      v = $0
      sub("^" k ":[[:space:]]*", "", v)
      sub(/^"/, "", v); sub(/"$/, "", v)
      print v
      exit
    }
  ' "$file" 2>/dev/null
}

# Extract `id` from a nested mapping — given a key like `subject.id`, walks
# into the `subject:` block. Limited to one level deep (enough for the
# review schema).
yaml_nested() {
  local file="$1" parent="$2" child="$3"
  awk -v p="$parent" -v c="$child" '
    $0 ~ "^" p ":[[:space:]]*$" { in_block=1; next }
    in_block==1 && /^[^[:space:]]/ { exit }
    in_block==1 && $0 ~ "^[[:space:]]+" c ":[[:space:]]*" {
      v = $0
      sub(/^[[:space:]]+/, "", v)
      sub("^" c ":[[:space:]]*", "", v)
      sub(/^"/, "", v); sub(/"$/, "", v)
      print v
      exit
    }
    # Inline form: `subject: {kind: task, id: X}`.
    $0 ~ "^" p ":[[:space:]]*\\{" {
      v = $0
      if (match(v, c ":[[:space:]]*[^,}]+")) {
        x = substr(v, RSTART, RLENGTH)
        sub("^" c ":[[:space:]]*", "", x)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", x)
        sub(/^"/, "", x); sub(/"$/, "", x)
        print x
        exit
      }
    }
  ' "$file" 2>/dev/null
}

# Extract a YAML list (either inline `[a, b]` or block `- a\n- b`) from
# a top-level key. Emits newline-separated values.
yaml_list() {
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { state=0 }
    /^body:[[:space:]]*\|[[:space:]]*$/ { exit }
    state==0 && $0 ~ "^" k ":[[:space:]]*\\[" {
      line = $0
      sub("^" k ":[[:space:]]*\\[", "", line)
      sub(/\].*$/, "", line)
      n = split(line, parts, ",")
      for (i=1; i<=n; i++) {
        s = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        sub(/^"/, "", s); sub(/"$/, "", s)
        if (s != "") print s
      }
      exit
    }
    state==0 && $0 ~ "^" k ":[[:space:]]*$" { state=1; next }
    state==1 {
      if (match($0, /^[[:space:]]+-[[:space:]]+/)) {
        v = $0
        sub(/^[[:space:]]+-[[:space:]]+/, "", v)
        sub(/^"/, "", v); sub(/"$/, "", v)
        print v
      } else if (match($0, /^[^[:space:]]/)) {
        exit
      }
    }
  ' "$file" 2>/dev/null
}

# Emit a compact inline JSON-ish YAML list `[a, b, c]` from newline-separated
# input. Empty input emits `[]`.
inline_list() {
  local raw first=1
  printf '['
  while IFS= read -r raw; do
    [ -z "$raw" ] && continue
    if [ "$first" -eq 1 ]; then first=0; else printf ', '; fi
    printf '%s' "$raw"
  done
  printf ']'
}

# Extract a scalar from the task's `links:` block (brief/debrief/release).
# Returns empty if the key is absent or `null`.
links_scalar() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^links:[[:space:]]*$/ { flag=1; next }
    flag && /^[^[:space:]]/ { exit }
    flag && $0 ~ "^[[:space:]]+" k ":" {
      v = $0
      sub("^[[:space:]]+" k ":[[:space:]]*", "", v)
      sub(/^"/, "", v); sub(/"$/, "", v)
      if (v == "null" || v == "") exit
      print v
      exit
    }
  ' "$file" 2>/dev/null
}

# Extract a list (inline `[a, b]` or block `- a\n- b`) from the task's
# `links:` block, scoped to the given key. Handles block-list with a
# lookahead that resets on the next sibling key.
links_list() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^links:[[:space:]]*$/ { in_links=1; next }
    in_links==1 && /^[^[:space:]]/ { exit }
    # Inline form on same line as the key.
    in_links==1 && $0 ~ "^[[:space:]]+" k ":[[:space:]]*\\[" {
      v = $0
      sub("^[[:space:]]+" k ":[[:space:]]*\\[", "", v)
      sub(/\].*$/, "", v)
      n = split(v, parts, ",")
      for (i=1; i<=n; i++) {
        s = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        sub(/^"/, "", s); sub(/"$/, "", s)
        if (s != "") print s
      }
      in_key = 0
      next
    }
    # Block form: `key:` on its own line, followed by `- item` lines.
    in_links==1 && $0 ~ "^[[:space:]]+" k ":[[:space:]]*$" {
      in_key=1
      next
    }
    # Leaving the list when another sibling key starts (e.g. `  release:`).
    in_links==1 && in_key==1 && /^[[:space:]]+[a-z_]+:/ && !/^[[:space:]]+-/ {
      in_key=0
    }
    in_links==1 && in_key==1 && /^[[:space:]]+-[[:space:]]+/ {
      v = $0
      sub(/^[[:space:]]+-[[:space:]]+/, "", v)
      sub(/^"/, "", v); sub(/"$/, "", v)
      if (v != "") print v
    }
  ' "$file" 2>/dev/null
}

emit_index() {
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf 'schema_version: {name: plans-index, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}\n'
  printf 'generated_at: %s\n' "$now"
  printf 'generator: scripts/rebuild-index.sh\n'
  printf 'project: %s\n' "$PROJECT"

  local kind singular_dir
  for kind in tasks briefs debriefs reviews rounds releases release-attempts feedback crashes; do
    singular_dir="$PLANS_DIR/$kind"
    printf '%s:\n' "$kind"
    [ -d "$singular_dir" ] || continue

    local f
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      [ -f "$f" ] || continue
      local id state
      id=$(yaml_scalar "$f" id)
      state=$(yaml_scalar "$f" state)
      [ -z "$id" ] && continue

      case "$kind" in
        tasks)
          local brief debrief release reviews feedback
          brief=$(links_scalar "$f" brief)
          debrief=$(links_scalar "$f" debrief)
          release=$(links_scalar "$f" release)
          reviews=$(links_list "$f" reviews)
          feedback=$(links_list "$f" feedback)
          printf '  - {id: %s, state: %s, brief: %s, debrief: %s, release: %s, reviews: %s, feedback: %s}\n' \
            "$id" "${state:-null}" "${brief:-null}" "${debrief:-null}" "${release:-null}" \
            "$(printf '%s\n' "$reviews"  | inline_list)" \
            "$(printf '%s\n' "$feedback" | inline_list)"
          ;;
        briefs)
          local task_id type size
          task_id=$(yaml_scalar "$f" task_id)
          type=$(yaml_scalar "$f" type)
          size=$(yaml_scalar "$f" size)
          printf '  - {id: %s, task_id: %s, type: %s, size: %s, state: %s}\n' \
            "$id" "${task_id:-null}" "${type:-null}" "${size:-null}" "${state:-null}"
          ;;
        debriefs)
          local task_id brief_id mode
          task_id=$(yaml_scalar "$f" task_id)
          brief_id=$(yaml_scalar "$f" brief_id)
          mode=$(yaml_scalar "$f" mode)
          printf '  - {id: %s, task_id: %s, brief_id: %s, mode: %s}\n' \
            "$id" "${task_id:-null}" "${brief_id:-null}" "${mode:-null}"
          ;;
        reviews)
          local reviewer subject_kind subject_id verdict
          reviewer=$(yaml_scalar "$f" reviewer)
          subject_kind=$(yaml_nested "$f" subject kind)
          subject_id=$(yaml_nested "$f" subject id)
          verdict=$(yaml_scalar "$f" verdict)
          printf '  - {id: %s, subject: {kind: %s, id: %s}, reviewer: %s, verdict: %s, state: %s}\n' \
            "$id" "${subject_kind:-null}" "${subject_id:-null}" "${reviewer:-null}" "${verdict:-null}" "${state:-null}"
          ;;
        rounds)
          local round_number scope tasks
          round_number=$(yaml_scalar "$f" round_number)
          scope=$(yaml_scalar "$f" scope)
          tasks=$(yaml_list "$f" tasks)
          printf '  - {id: %s, round_number: %s, scope: %s, state: %s, tasks: %s}\n' \
            "$id" "${round_number:-null}" "${scope:-null}" "${state:-null}" \
            "$(printf '%s\n' "$tasks" | inline_list)"
          ;;
        releases)
          local channel version tag tasks
          channel=$(yaml_scalar "$f" channel)
          version=$(yaml_scalar "$f" version)
          tag=$(yaml_scalar "$f" tag)
          tasks=$(yaml_list "$f" tasks)
          printf '  - {id: %s, channel: %s, version: %s, tag: %s, state: %s, tasks: %s}\n' \
            "$id" "${channel:-null}" "${version:-null}" "${tag:-null}" "${state:-null}" \
            "$(printf '%s\n' "$tasks" | inline_list)"
          ;;
        release-attempts)
          local operation channel from_release_id to_release_id
          operation=$(yaml_scalar "$f" operation)
          channel=$(yaml_scalar "$f" channel)
          from_release_id=$(yaml_nested "$f" intent from_release_id)
          to_release_id=$(yaml_nested "$f" intent to_release_id)
          printf '  - {id: %s, operation: %s, channel: %s, state: %s, from_release_id: %s, to_release_id: %s}\n' \
            "$id" "${operation:-null}" "${channel:-null}" "${state:-null}" \
            "${from_release_id:-null}" "${to_release_id:-null}"
          ;;
        feedback)
          local source linked_tasks
          source=$(yaml_scalar "$f" source)
          linked_tasks=$(yaml_list "$f" linked_tasks)
          printf '  - {id: %s, source: %s, state: %s, linked_tasks: %s}\n' \
            "$id" "${source:-null}" "${state:-null}" \
            "$(printf '%s\n' "$linked_tasks" | inline_list)"
          ;;
        crashes)
          local linked_tasks linked_feedback
          linked_tasks=$(yaml_list "$f" linked_tasks)
          linked_feedback=$(yaml_list "$f" linked_feedback)
          printf '  - {id: %s, state: %s, linked_tasks: %s, linked_feedback: %s}\n' \
            "$id" "${state:-null}" \
            "$(printf '%s\n' "$linked_tasks" | inline_list)" \
            "$(printf '%s\n' "$linked_feedback" | inline_list)"
          ;;
      esac
    done < <(find "$singular_dir" -maxdepth 1 -type f -name '*.yaml' 2>/dev/null | sort)
  done
}

case "$MODE" in
  stdout)
    emit_index
    ;;
  validate)
    # Emit to tmp, compare to canonical. Exit 1 on drift.
    tmp=$(mktemp)
    emit_index > "$tmp"
    if [ ! -f "$INDEX_PATH" ] || ! diff -q "$INDEX_PATH" "$tmp" >/dev/null 2>&1; then
      printf 'plans/index.yaml drift — rerun scripts/rebuild-index.sh\n' >&2
      [ -f "$INDEX_PATH" ] && diff -u "$INDEX_PATH" "$tmp" >&2 || cat "$tmp" >&2
      rm -f "$tmp"
      exit 1
    fi
    rm -f "$tmp"
    ;;
  write)
    mkdir -p "$(dirname "$INDEX_PATH")"
    tmp=$(mktemp)
    emit_index > "$tmp"
    mv "$tmp" "$INDEX_PATH"
    printf 'plans/index.yaml written: %s\n' "$INDEX_PATH"
    ;;
esac
