#!/usr/bin/env bash
# query-tasks.sh — walks plans/tasks/*.yaml for queries over lean-schema
# fields (train, predecessors, history) that plans/index.yaml does not carry.
#
# Usage:
#   scripts/query-tasks.sh --train=<name>
#   scripts/query-tasks.sh --state=<state>
#   scripts/query-tasks.sh --state=<state> --state-age-gt=<days>
#   scripts/query-tasks.sh --predecessor-of=<uuid>
#   scripts/query-tasks.sh --dispatch-ready
#   scripts/query-tasks.sh --train=<name> --format=json
#
# Filters compose with AND. Default output is TSV:
#   <id>\t<state>\t<train|->\t<title>\t<updated_at>
# --format=json emits a JSON array.
#
# --dispatch-ready implies --state=briefed and additionally requires every
# predecessor in {merged, verified, archived}.
#
# Requires `yq` (v4) and `jq`. Read-only.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

PROJECT=""
TRAIN=""
STATE=""
STATE_AGE_GT=""
PREDECESSOR_OF=""
DISPATCH_READY=0
FORMAT="tsv"

while [ $# -gt 0 ]; do
  case "$1" in
    --project)            PROJECT="${2:?--project requires slug}"; shift 2 ;;
    --train=*)            TRAIN="${1#--train=}"; shift ;;
    --state=*)            STATE="${1#--state=}"; shift ;;
    --state-age-gt=*)     STATE_AGE_GT="${1#--state-age-gt=}"; shift ;;
    --predecessor-of=*)   PREDECESSOR_OF="${1#--predecessor-of=}"; shift ;;
    --dispatch-ready)     DISPATCH_READY=1; STATE="briefed"; shift ;;
    --format=*)           FORMAT="${1#--format=}"; shift ;;
    -h|--help)
      sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 2 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v yq >/dev/null 2>&1 || { printf 'error: yq (v4) required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }

case "$FORMAT" in
  tsv|json) ;;
  *) printf 'error: --format must be tsv or json\n' >&2; exit 2 ;;
esac

if [ -z "$PROJECT" ]; then
  PROJECT=$(resolve_project 2>/dev/null) || {
    printf 'error: no project resolved. Pass --project <slug>.\n' >&2
    exit 2
  }
fi

TASKS_DIR=$(resolve_tasks_dir_for "$PROJECT")
if [ ! -d "$TASKS_DIR" ]; then
  printf 'error: tasks dir not found: %s\n' "$TASKS_DIR" >&2
  exit 2
fi

# Project each task file into a small JSON record. Missing 1.1.0 fields
# (train, predecessors) default so jq predicates do not choke on
# 1.0.0 artifacts.
ALL=$(
  for f in "$TASKS_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    yq -o=json '.' "$f" 2>/dev/null \
      | jq '{
          id, title, state,
          train: (.train // null),
          predecessors: (.predecessors // []),
          priority: (.priority // "p2"),
          effort_minutes: (.effort_minutes // null),
          recommended_model: (.recommended_model // null),
          updated_at,
          history_at: ((.history // []) | (last.at // .updated_at))
        }'
  done | jq -s '.'
)

# id→state map for the dispatch-ready predecessor join.
STATE_MAP=$(printf '%s' "$ALL" | jq 'map({(.id): .state}) | add // {}')

FILTER='.[]'
[ -n "$TRAIN" ]          && FILTER="$FILTER | select(.train == \"$TRAIN\")"
[ -n "$STATE" ]          && FILTER="$FILTER | select(.state == \"$STATE\")"
[ -n "$PREDECESSOR_OF" ] && FILTER="$FILTER | select(.predecessors | index(\"$PREDECESSOR_OF\"))"
if [ -n "$STATE_AGE_GT" ]; then
  FILTER="$FILTER | select(((now - (.history_at | fromdateiso8601)) / 86400) > $STATE_AGE_GT)"
fi
if [ "$DISPATCH_READY" -eq 1 ]; then
  FILTER="$FILTER"' | select(.predecessors | all(. as $p | ($map[$p] // "missing") | IN("merged","verified","archived")))'
fi

case "$FORMAT" in
  json)
    printf '%s' "$ALL" | jq --argjson map "$STATE_MAP" "[$FILTER]"
    ;;
  tsv)
    printf '%s' "$ALL" | jq -r --argjson map "$STATE_MAP" \
      "$FILTER | [.id, .state, (.train // \"-\"), .title, .updated_at] | @tsv"
    ;;
esac
