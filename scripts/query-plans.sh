#!/usr/bin/env bash
# query-plans.sh — thin wrapper over `yq` that lets agents query the plans
# relational index without globbing or hand-parsing YAML.
#
# Usage:
#   scripts/query-plans.sh --kind=task --state=verified
#   scripts/query-plans.sh --kind=brief --task-id=<uuidv7>
#   scripts/query-plans.sh --kind=review --subject-kind=task --subject-id=<uuidv7>
#   scripts/query-plans.sh --kind=release --channel=testflight --state=released
#   scripts/query-plans.sh --kind=feedback --source=slack-thread
#   scripts/query-plans.sh --format=json   # emit JSON instead of YAML-inline
#
# Emits one line per matching artifact. Without --format=json, each line is
# the inline-YAML row from index.yaml (compact, readable). With --format=json,
# each line is a JSON object suitable for `jq`.
#
# Requires `yq` (v4+). If absent, falls back to an awk-based filter that
# supports a subset (--kind + --state). The fallback is best-effort and
# warns on stderr.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

PROJECT=""
KIND=""
FORMAT="yaml"
TOUCHES_GLOB=""
declare -a FILTERS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --project)    PROJECT="${2:?--project requires slug}"; shift 2 ;;
    --kind=*)     KIND="${1#--kind=}"; shift ;;
    --kind)       KIND="${2:?--kind requires value}"; shift 2 ;;
    --format=*)   FORMAT="${1#--format=}"; shift ;;
    --format)     FORMAT="${2:?--format requires value}"; shift 2 ;;
    --touches=*)  TOUCHES_GLOB="${1#--touches=}"; shift ;;
    --touches)    TOUCHES_GLOB="${2:?--touches requires a glob}"; shift 2 ;;
    --*=*)        FILTERS+=("$1"); shift ;;
    -h|--help)
      sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 2 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# --touches: reverse-index query over affinity.touchpoints.
# Scans per-task YAMLs directly (index doesn't store touchpoints).
if [ -n "$TOUCHES_GLOB" ]; then
  if [ -z "$PROJECT" ]; then
    PROJECT=$(resolve_project 2>/dev/null) || {
      printf 'error: no project resolved. Pass --project <slug>.\n' >&2
      exit 2
    }
  fi
  if [ -n "${ACHILLES_PROJECT_ROOT:-}" ]; then
    _TP_ROOT="$ACHILLES_PROJECT_ROOT"
  else
    _TP_ROOT=$(resolve_project_root_for "$PROJECT")
  fi
  _TP_DIR="$_TP_ROOT/plans/tasks"
  command -v yq >/dev/null 2>&1 || { printf 'error: --touches requires yq (v4+)\n' >&2; exit 2; }
  [ -d "$_TP_DIR" ] || { printf 'no tasks dir: %s\n' "$_TP_DIR" >&2; exit 0; }
  _found=0
  for _f in "$_TP_DIR"/*.yaml; do
    [ -f "$_f" ] || continue
    if yq -e '.affinity.touchpoints[]? | select(. != null) | select(test("'"$TOUCHES_GLOB"'"))' \
        "$_f" >/dev/null 2>&1; then
      yq eval '.' "$_f"
      _found=$(( _found + 1 ))
    fi
  done
  [ "$_found" -gt 0 ] || printf 'no tasks with touchpoints matching: %s\n' "$TOUCHES_GLOB" >&2
  exit 0
fi

if [ -z "$KIND" ]; then
  printf 'error: --kind is required (one of tasks, briefs, debriefs, reviews, rounds, releases, feedback, crashes)\n' >&2
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

INDEX_PATH="$PROJECT_ROOT/plans/index.yaml"
if [ ! -f "$INDEX_PATH" ]; then
  printf 'error: index not found (%s) — run scripts/rebuild-index.sh\n' "$INDEX_PATH" >&2
  exit 2
fi

# Preferred path: yq v4.
if command -v yq >/dev/null 2>&1; then
  # Build the yq filter expression incrementally.
  local_expr=".${KIND}[]"
  for flt in "${FILTERS[@]:-}"; do
    [ -z "$flt" ] && continue
    # --foo=bar → select(.foo == "bar"). For --subject-kind=task we map to
    # .subject.kind. Treat --task-id as .task_id.
    key="${flt%%=*}"
    val="${flt#*=}"
    key="${key#--}"
    # Canonicalize common aliases.
    case "$key" in
      task-id)       key="task_id" ;;
      subject-kind)  key=".subject.kind" ;;
      subject-id)    key=".subject.id" ;;
      *)             key="${key//-/_}" ;;
    esac
    if [ "${key:0:1}" != "." ]; then
      key=".$key"
    fi
    local_expr="$local_expr | select($key == \"$val\")"
  done

  case "$FORMAT" in
    yaml)
      yq eval -o=yaml "$local_expr" "$INDEX_PATH" 2>/dev/null || {
        printf 'query returned no matches or yq error\n' >&2
        exit 0
      }
      ;;
    json)
      yq eval -o=json "$local_expr" "$INDEX_PATH" 2>/dev/null || {
        printf 'query returned no matches or yq error\n' >&2
        exit 0
      }
      ;;
    *)
      printf 'error: --format must be yaml or json\n' >&2
      exit 2
      ;;
  esac
  exit 0
fi

# Fallback: awk-based filter supporting --kind + --state.
printf 'warn: yq not found — using awk fallback (supports --kind + --state only)\n' >&2
state_filter=""
for flt in "${FILTERS[@]:-}"; do
  case "$flt" in
    --state=*) state_filter="${flt#--state=}" ;;
  esac
done

awk -v k="$KIND" -v sf="$state_filter" '
  $0 ~ "^" k ":" { in_block=1; next }
  in_block==1 && /^[a-z]+:/ { in_block=0 }
  in_block==1 && /^[[:space:]]+-[[:space:]]*{/ {
    if (sf == "") { print; next }
    if (match($0, /state:[[:space:]]*[a-z_-]+/)) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^state:[[:space:]]*/, "", s)
      if (s == sf) print
    }
  }
' "$INDEX_PATH"
