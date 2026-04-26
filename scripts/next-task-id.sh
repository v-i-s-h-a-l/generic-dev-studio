#!/usr/bin/env bash
# next-task-id.sh — deterministic allocator for human-readable legacy_task_id.
#
# Post-Phase-2.6 canonical task id is a UUIDv7. The `legacy_task_id:` field
# (T001, T002, …) is a display convenience users still think in. This script
# is the single source of truth for "what's the next free T-number".
#
# Reads every known source (YAML legacy_task_id, master plan, legacy md
# filenames, event log) and prints max+1. Callers treat the result as opaque.
#
# Usage:
#   scripts/next-task-id.sh                    # default prefix T -> e.g. T268
#   scripts/next-task-id.sh --prefix=TBUILD    # -> TBUILD-5
#   scripts/next-task-id.sh --prefix=TUNIT     # -> TUNIT-3
#   scripts/next-task-id.sh --project=<slug>   # override auto-detection
#   scripts/next-task-id.sh --explain          # also print per-source counts (stderr)
#
# Exit codes:
#   0  next id printed to stdout
#   2  cannot resolve project
#   64 bad args

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

PREFIX="T"
PROJECT=""
EXPLAIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix=*)  PREFIX="${1#--prefix=}" ;;
    --project=*) PROJECT="${1#--project=}" ;;
    --explain)   EXPLAIN=1 ;;
    --help|-h)   sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           printf 'unknown arg: %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done

[ -z "$PROJECT" ] && PROJECT=$(resolve_project 2>/dev/null || echo "")
[ -z "$PROJECT" ] && { printf 'cannot resolve project — pass --project=<slug>\n' >&2; exit 2; }

TASKS_DIR=$(resolve_tasks_dir_for "$PROJECT")
EVENTS_DIR=$(resolve_events_dir_for "$PROJECT")

# "T" is a bare prefix (T001); "TBUILD"/"TUNIT" use a dash separator (TBUILD-1).
# The dash disambiguates TUNIT-3 from unrelated TUNITx matches.
if [ "$PREFIX" = "T" ]; then
  SEP=''
else
  SEP='-'
fi
TOKEN_RE="${PREFIX}${SEP}[0-9]+"

# Emit numeric suffixes from each source to stdout (one per line). Post-#245
# A.4 the legacy master-plan + chanakya-tasks dir are archived; both YAML
# `legacy_task_id` fields and event-log mentions are sufficient to keep the
# allocator monotonic.
collect_numbers() {
  if [ -d "$TASKS_DIR" ]; then
    grep -hEo "legacy_task_id: *\"?${TOKEN_RE}" "$TASKS_DIR"/*.yaml 2>/dev/null \
      | grep -oE '[0-9]+$'
  fi
  if [ -d "$EVENTS_DIR" ]; then
    grep -hoE "\"${TOKEN_RE}\"" "$EVENTS_DIR"/*.jsonl 2>/dev/null \
      | grep -oE '[0-9]+'
  fi
}

# Per-source counts are useful for --explain; compute them only if asked.
src_yaml=0 src_events=0
if [ "$EXPLAIN" = "1" ]; then
  [ -d "$TASKS_DIR" ] && src_yaml=$(
    grep -hEo "legacy_task_id: *\"?${TOKEN_RE}" "$TASKS_DIR"/*.yaml 2>/dev/null | wc -l | tr -d ' '
  )
  [ -d "$EVENTS_DIR" ] && src_events=$(
    grep -hoE "\"${TOKEN_RE}\"" "$EVENTS_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' '
  )
fi

# sort -n + tail -1 is bash-3.2 and zsh safe; handles empty input gracefully.
max_n=$(collect_numbers | sort -n | tail -1)
[ -z "$max_n" ] && max_n=0

next_n=$(( max_n + 1 ))

if [ "$EXPLAIN" = "1" ]; then
  printf 'next-task-id: project=%s prefix=%s max=%s next=%s sources=yaml:%s,events:%s\n' \
    "$PROJECT" "$PREFIX" "$max_n" "$next_n" "$src_yaml" "$src_events" >&2
fi

if [ "$PREFIX" = "T" ]; then
  printf 'T%03d\n' "$next_n"
else
  printf '%s-%d\n' "$PREFIX" "$next_n"
fi
