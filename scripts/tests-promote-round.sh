#!/usr/bin/env bash
# tests-promote-round.sh — Step 9 promote subcommand for /chanakya test-flow.
#
# Gates on "every case has a final verdict" (pass or fail, no `[ ]` unchecked
# leftovers) and, on pass, renders a pre-checked user-testing.md so
# /chanakya review-feedback can mark tasks verified in one shot.
#
# Usage:
#   scripts/tests-promote-round.sh <round-number>
#
# Exit codes:
#   0  promoted — user-testing.md rewritten with pass rows pre-checked
#   2  round not found, missing yq on YAML surface, or other resolution error
#   3  gate failed — count of unchecked cases printed to stderr

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

ROUND_NUM="${1:-}"
if [ -z "$ROUND_NUM" ]; then
  printf 'usage: tests-promote-round.sh <round-number>\n' >&2
  exit 2
fi

PROJECT=$(resolve_project 2>/dev/null) || { printf 'error: no project resolved\n' >&2; exit 2; }
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
ROUNDS_DIR="$PROJECT_ROOT/plans/rounds"
LEGACY="$PROJECT_ROOT/plans/user-testing-rounds/user-testing-round${ROUND_NUM}.md"
DEST="$PROJECT_ROOT/plans/user-testing.md"

# Resolve round source. YAML preferred — scan plans/rounds for the matching
# round_number. Legacy markdown is the Phase 2.6 transition fallback.
YAML_SRC=""
if command -v yq >/dev/null 2>&1 && [ -d "$ROUNDS_DIR" ]; then
  for y in "$ROUNDS_DIR"/*.yaml; do
    [ -f "$y" ] || continue
    rn=$(yq -r '.round_number // ""' "$y" 2>/dev/null || echo "")
    if [ "$rn" = "$ROUND_NUM" ]; then
      YAML_SRC="$y"
      break
    fi
  done
fi

if [ -z "$YAML_SRC" ] && [ ! -f "$LEGACY" ]; then
  printf 'error: round %s not found (YAML or legacy)\n' "$ROUND_NUM" >&2
  exit 2
fi

# Gate: every case must carry a final `[x] pass` or `[x] fail`. YAML surface
# inspects `cases[].result`; legacy parses `Result: [x] pass  [ ] fail` lines.
unchecked=0
fail_count=0
pass_count=0

if [ -n "$YAML_SRC" ]; then
  # yq treats the schema's `cases: []` as an empty array; every case record
  # has a required `result` per the schema — but we guard against missing
  # values by defaulting to `pending`.
  summary=$(yq -r '.cases // [] | [.[].result // "pending"] | @csv' "$YAML_SRC" 2>/dev/null || echo "")
  IFS=',' read -r -a results <<< "${summary//\"/}"
  for r in "${results[@]:-}"; do
    case "$r" in
      pass)           pass_count=$((pass_count + 1)) ;;
      fail)           fail_count=$((fail_count + 1)) ;;
      pending|""|null) unchecked=$((unchecked + 1)) ;;
    esac
  done
else
  # Legacy: count `Result:` lines by the state of their `[x]` markers.
  # A case is "final" iff exactly one of pass/fail is checked.
  while IFS= read -r line; do
    pass_checked=0
    fail_checked=0
    if printf '%s' "$line" | grep -qE '\[[xX]\][[:space:]]*pass'; then
      pass_checked=1
    fi
    if printf '%s' "$line" | grep -qE '\[[xX]\][[:space:]]*fail'; then
      fail_checked=1
    fi
    if [ "$pass_checked" = "1" ] && [ "$fail_checked" = "0" ]; then
      pass_count=$((pass_count + 1))
    elif [ "$fail_checked" = "1" ] && [ "$pass_checked" = "0" ]; then
      fail_count=$((fail_count + 1))
    else
      unchecked=$((unchecked + 1))
    fi
  done < <(grep -E '^Result:' "$LEGACY" 2>/dev/null || true)
fi

if [ "$unchecked" -gt 0 ]; then
  printf 'gate: %s unchecked cases remain (pass=%s, fail=%s)\n' \
    "$unchecked" "$pass_count" "$fail_count" >&2
  exit 3
fi

ts=$(date +"%Y-%m-%d %H:%M %Z")
display_name=$(resolve_display_name 2>/dev/null || printf '%s' "$PROJECT")

# Render manifest. Task ids + per-case titles come from the round artifact;
# each passing case is pre-checked, each failing case is left unchecked with
# a `Notes: round <N> failure` annotation so review-feedback surfaces it.
tmp=$(mktemp)
{
  printf '# User Testing — %s\n\n' "$display_name"
  printf 'Generated: %s  (promoted from round %s)\n' "$ts" "$ROUND_NUM"

  if [ -n "$YAML_SRC" ]; then
    # Collect tasks covered by this round (prefer legacy_task_id when linked).
    tasks_list=$(yq -r '.tasks // [] | join(", ")' "$YAML_SRC" 2>/dev/null || echo "")
    [ -z "$tasks_list" ] && tasks_list="(none)"
    printf 'Tasks awaiting verification: %s\n\n' "$tasks_list"
    printf -- '---\n'
    # Group cases by first task_ref so the manifest aligns with the per-task
    # manifest shape review-feedback expects.
    yq -r '
      .cases // [] |
      group_by(.task_refs[0] // "unknown") |
      .[] |
      "TASK\t" + (.[0].task_refs[0] // "unknown") + "\n" +
      (map("CASE\t" + (.result // "pending") + "\t" + (.title // "untitled")) | join("\n"))
    ' "$YAML_SRC" 2>/dev/null | while IFS=$'\t' read -r kind a b; do
      case "$kind" in
        TASK)
          printf '\n## %s\n' "$a"
          ;;
        CASE)
          result="$a"; title="$b"
          if [ "$result" = "pass" ]; then
            printf -- '- [x] %s\n' "$title"
            printf '  Notes: passed in round %s\n' "$ROUND_NUM"
          else
            printf -- '- [ ] %s\n' "$title"
            printf '  Notes: round %s %s\n' "$ROUND_NUM" "$result"
          fi
          ;;
      esac
    done
  else
    # Legacy surface — parse section headings + `Result: [x] pass` lines.
    task_ids=$(grep -oE '\[T[0-9A-Za-z-]+\]' "$LEGACY" 2>/dev/null | tr -d '[]' | sort -u | paste -sd ',' - | sed 's/,/, /g')
    [ -z "$task_ids" ] && task_ids="(none)"
    printf 'Tasks awaiting verification: %s\n\n' "$task_ids"
    printf -- '---\n\n'
    printf '## (promoted from legacy round %s)\n\n' "$ROUND_NUM"
    # Walk `### <id>` case headers + the following `Result:` line.
    awk '
      /^###[[:space:]]/ { cur=$0; sub(/^###[[:space:]]*/, "", cur); next }
      /^Result:/ && cur != "" {
        ok=0; fail=0
        if ($0 ~ /\[[xX]\][[:space:]]*pass/) ok=1
        if ($0 ~ /\[[xX]\][[:space:]]*fail/) fail=1
        if (ok && !fail) printf "PASS\t%s\n", cur
        else if (fail && !ok) printf "FAIL\t%s\n", cur
        cur=""
      }
    ' "$LEGACY" | while IFS=$'\t' read -r verdict title; do
      if [ "$verdict" = "PASS" ]; then
        printf -- '- [x] %s\n' "$title"
        printf '  Notes: passed in round %s\n' "$ROUND_NUM"
      else
        printf -- '- [ ] %s\n' "$title"
        printf '  Notes: round %s failure\n' "$ROUND_NUM"
      fi
    done
  fi
} > "$tmp"

mkdir -p "$(dirname "$DEST")" 2>/dev/null || true
mv "$tmp" "$DEST" || { rm -f "$tmp"; exit 2; }

exit 0
