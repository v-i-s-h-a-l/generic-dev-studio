#!/usr/bin/env bash
# tests-write-manifest.sh — Step 4 manifest write.
#
# Reads a YAML/JSON task bundle from stdin and renders it to
# plans/user-testing.md (the user-facing checklist surface, not a Phase 2.6
# canonical artifact — intentionally bypasses lib-ledger).
#
# Usage:
#   scripts/tests-write-manifest.sh [--force]
#
# Stdin shape (YAML):
#   tasks:
#     - id: T001
#       title: "..."
#       debrief_path: "..."
#       cases:
#         - title: "..."
#           preconditions: "..."
#           steps: ["..."]
#           expected: "..."
#
# Exit codes:
#   0  manifest written
#   2  dirty destination without --force, or missing yq/jq when parsing stdin

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help)
      sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 2 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }
DEST="$(resolve_plans_dir_for "$PROJECT")/user-testing.md"

# Dirty-state guard delegates to the shared script so the rule stays in one
# place — test-manifest regen and promote flow both call it.
if [ "$FORCE" = "0" ]; then
  if ! "$SCRIPT_DIR/tests-dirty-state-check.sh" "$DEST"; then
    printf 'error: %s is dirty; pass --force to overwrite\n' "$DEST" >&2
    exit 2
  fi
fi

command -v yq >/dev/null 2>&1 || { printf 'error: yq required\n' >&2; exit 2; }

payload=$(cat)
if [ -z "$payload" ]; then
  printf 'error: empty stdin (expected tasks bundle)\n' >&2
  exit 2
fi

# Normalize stdin to JSON — yq handles both YAML and JSON input.
json=$(printf '%s' "$payload" | yq -o=json '.' 2>/dev/null) || {
  printf 'error: could not parse stdin as YAML/JSON\n' >&2
  exit 2
}

tcount=$(printf '%s' "$json" | jq -r '.tasks | length // 0' 2>/dev/null)
tcount=${tcount:-0}

task_ids=$(printf '%s' "$json" | jq -r '.tasks[]?.id' 2>/dev/null | paste -sd ',' - | sed 's/,/, /g')
[ -z "$task_ids" ] && task_ids="(none)"

ts=$(date +"%Y-%m-%d %H:%M %Z")
display_name=$(resolve_display_name 2>/dev/null || printf '%s' "$PROJECT")

tmp=$(mktemp)
{
  printf '# User Testing — %s\n\n' "$display_name"
  printf 'Generated: %s\n' "$ts"
  printf 'Tasks awaiting verification: %s\n\n' "$task_ids"
  printf 'Instructions:\n'
  printf -- '- Tick `[ ]` → `[x]` for each case that passes.\n'
  printf -- '- Write any failure or issue under the `Notes:` line below the case.\n'
  printf -- '- When done, run `/dev-studio manager review-feedback` to apply your edits to the master plan.\n\n'
  printf -- '---\n'

  # One section per task. jq emits a tab-separated record per case; array steps
  # are flattened for the human-facing checklist while YAML keeps structure.
  printf '%s' "$json" | jq -r '
    def steps_text:
      if (.steps // []) | type == "array" then
        (.steps // [] | join(" / "))
      else
        (.steps // "")
      end;
    .tasks[]? |
    (["TASK", (.id // "—"), (.title // "—"), (.debrief_path // "")] | @tsv) + "\n" +
    ((.cases // []) | map(
      ["CASE", (.title // "untitled"), (.preconditions // ""), steps_text, (.expected // "")] | @tsv
    ) | join("\n"))
  ' 2>/dev/null | while IFS=$'\t' read -r kind a b c d; do
    case "$kind" in
      TASK)
        printf '\n## %s — %s\n' "$a" "$b"
        if [ -n "$c" ] && [ "$c" != "null" ]; then
          printf 'Debrief: `%s`\n\n' "$c"
        else
          printf '\n'
        fi
        ;;
      CASE)
        # Synthesize the user-facing case line: preconditions → steps → expected.
        pre="$b"; steps="$c"; exp="$d"
        summary="$a"
        if [ -n "$pre" ] || [ -n "$steps" ] || [ -n "$exp" ]; then
          summary="$a:"
          [ -n "$pre" ]   && summary="$summary $pre →"
          [ -n "$steps" ] && summary="$summary $steps →"
          [ -n "$exp" ]   && summary="$summary $exp"
        fi
        printf -- '- [ ] %s\n' "$summary"
        printf '  Notes: \n'
        ;;
    esac
  done

  # Placeholder when a task has no cases — mirrors the mode pack's prose.
  if [ "$tcount" -gt 0 ]; then
    printf '\n'
  fi
} > "$tmp"

mkdir -p "$(dirname "$DEST")" 2>/dev/null || true
mv "$tmp" "$DEST" || { rm -f "$tmp"; exit 2; }

exit 0
