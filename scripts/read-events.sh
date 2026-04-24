#!/usr/bin/env bash
# read-events.sh — stream events with reader-side dedupe per the event-emission contract.
#
# Usage:
#   scripts/read-events.sh                                    # current project, deduped
#   scripts/read-events.sh --project <slug>                   # another project
#   scripts/read-events.sh --date YYYY-MM-DD                  # single day
#   scripts/read-events.sh --since YYYY-MM-DD --until YYYY-MM-DD
#   scripts/read-events.sh --agent achilles|argus|chanakya
#   scripts/read-events.sh --event task_completed
#   scripts/read-events.sh --task T001
#   scripts/read-events.sh --gen-ai-system claude-code|codex  # filter by OTel gen_ai.system
#   scripts/read-events.sh --tail 20
#   scripts/read-events.sh --no-dedupe                        # raw stream
#
# Dedupe rule: first occurrence of (producer.agent, idempotency_key) wins.
# Events without idempotency_key pass through unchanged (session/snapshot events).
# See _shared/contracts/event-emission.md.
#
# OTel backward-compat: pre-H5 events have no gen_ai.* attrs. --gen-ai-system
# treats a missing gen_ai.system field as "claude-code" (the only host that
# existed before host-agnostic workers v1 shipped).
#
# Emits one JSON event per line. Requires `jq`.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

PROJECT=""
DATE=""
SINCE=""
UNTIL=""
AGENT=""
EVENT=""
TASK=""
GEN_AI_SYSTEM=""
DEDUPE=1
TAIL=""

usage() {
  sed -n '2,/^# Emits/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project=*)  PROJECT="${1#--project=}"; shift ;;
    --project)    PROJECT="${2:?--project requires slug}"; shift 2 ;;
    --date=*)     DATE="${1#--date=}"; shift ;;
    --date)       DATE="${2:?--date requires YYYY-MM-DD}"; shift 2 ;;
    --since=*)    SINCE="${1#--since=}"; shift ;;
    --since)      SINCE="${2:?--since requires YYYY-MM-DD}"; shift 2 ;;
    --until=*)    UNTIL="${1#--until=}"; shift ;;
    --until)      UNTIL="${2:?--until requires YYYY-MM-DD}"; shift 2 ;;
    --agent=*)    AGENT="${1#--agent=}"; shift ;;
    --agent)      AGENT="${2:?--agent requires value}"; shift 2 ;;
    --event=*)    EVENT="${1#--event=}"; shift ;;
    --event)      EVENT="${2:?--event requires value}"; shift 2 ;;
    --task=*)     TASK="${1#--task=}"; shift ;;
    --task)       TASK="${2:?--task requires value}"; shift 2 ;;
    --gen-ai-system=*) GEN_AI_SYSTEM="${1#--gen-ai-system=}"; shift ;;
    --gen-ai-system)   GEN_AI_SYSTEM="${2:?--gen-ai-system requires value}"; shift 2 ;;
    --tail=*)     TAIL="${1#--tail=}"; shift ;;
    --tail)       TAIL="${2:?--tail requires N}"; shift 2 ;;
    --no-dedupe)  DEDUPE=0; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { printf 'error: jq required (brew install jq)\n' >&2; exit 2; }

if [ -z "$PROJECT" ]; then
  PROJECT=$(resolve_project 2>/dev/null) || {
    printf 'error: no project resolved. Pass --project <slug> or run inside a project git repo.\n' >&2
    exit 2
  }
fi

PROJECT_ROOT=$(resolve_project_root_for "$PROJECT") || {
  printf 'error: could not resolve project root for %s\n' "$PROJECT" >&2
  exit 2
}
EVENTS_DIR="$PROJECT_ROOT/events"
[ -d "$EVENTS_DIR" ] || {
  printf 'error: no events dir at %s\n' "$EVENTS_DIR" >&2
  exit 2
}

# Collect day-partitioned files. YYYY-MM-DD.jsonl only — skip legacy siblings
# (agents.jsonl, events.jsonl) since those are pre-2.6 cruft in the same dir.
FILES=()
if [ -n "$DATE" ]; then
  [ -f "$EVENTS_DIR/$DATE.jsonl" ] && FILES+=("$EVENTS_DIR/$DATE.jsonl")
else
  while IFS= read -r f; do
    base=$(basename "$f" .jsonl)
    case "$base" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
      *) continue ;;
    esac
    [ -n "$SINCE" ] && [ "$base" \< "$SINCE" ] && continue
    [ -n "$UNTIL" ] && [ "$base" \> "$UNTIL" ] && continue
    FILES+=("$f")
  done < <(find "$EVENTS_DIR" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null | sort)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  exit 0
fi

# Event-level filter composed into one jq expression. Quote with care — values
# go into a jq string literal, so we reject any embedded double-quote to stay safe.
for v in "$AGENT" "$EVENT" "$TASK"; do
  case "$v" in *\"*) printf 'error: filter values may not contain double quotes\n' >&2; exit 2 ;; esac
done

JQ_FILTER='.'
[ -n "$AGENT" ]          && JQ_FILTER="$JQ_FILTER | select((.producer.agent // .agent // \"\") == \"$AGENT\")"
[ -n "$EVENT" ]          && JQ_FILTER="$JQ_FILTER | select(.event == \"$EVENT\")"
[ -n "$TASK" ]           && JQ_FILTER="$JQ_FILTER | select(.task == \"$TASK\")"
# gen_ai.system filter: missing attr treated as "claude-code" (backward-compat for pre-H5 events).
[ -n "$GEN_AI_SYSTEM" ]  && JQ_FILTER="$JQ_FILTER | select((.\"gen_ai.system\" // \"claude-code\") == \"$GEN_AI_SYSTEM\")"

stream() {
  cat "${FILES[@]}" | jq -c "$JQ_FILTER" 2>/dev/null
}

if [ "$DEDUPE" -eq 1 ]; then
  stream \
    | jq -cr '
        (.idempotency_key // null) as $k
        | if $k == null
          then "P\t\t" + tojson
          else "D\t" + (.producer.agent // .agent // "") + "|" + $k + "\t" + tojson
          end
      ' \
    | awk -F'\t' '
        $1 == "P" { print $3; next }
        $1 == "D" { if (!seen[$2]++) print $3 }
      '
else
  stream
fi \
  | { if [ -n "$TAIL" ]; then tail -n "$TAIL"; else cat; fi; }
