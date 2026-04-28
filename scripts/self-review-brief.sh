#!/usr/bin/env bash
# self-review-brief.sh — pre-`ready` brief gate (#162 trimmed slice).
#
# The single script Chanakya's brief mode invokes before flipping a brief
# from `draft` to `ready`. Composes the existing summary lint with the new
# inheritance check; intended as the load-bearing place to add future brief
# gates (Mechanism 5 in #162) so callers stay one-line.
#
# Usage:
#   scripts/self-review-brief.sh <brief.yaml>
#       Run summary lint (always) + inheritance check (if --predecessor given).
#
#   scripts/self-review-brief.sh <brief.yaml> \
#       --predecessor <debrief.yaml> [--predecessor <debrief.yaml> ...]
#       Same, plus assert each predecessor's concerns appear in the brief body.
#
# Exit 0: all checks pass. Exit 1: any block-level violation. Exit 2: bad args.

set -u
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

BRIEF=""
PRED_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    --predecessor) PRED_ARGS+=("$1" "$2"); shift 2 ;;
    -*) echo "E_BAD_FLAG: unknown $1" >&2; exit 2 ;;
    *) [ -z "$BRIEF" ] && BRIEF="$1" || { echo "E_BAD_ARG: $1" >&2; exit 2; }; shift ;;
  esac
done

[ -n "$BRIEF" ] || { echo "usage: self-review-brief.sh <brief.yaml> [--predecessor <debrief.yaml> ...]" >&2; exit 2; }

FAIL=0

if ! "$SCRIPT_DIR/lint-brief.sh" "$BRIEF"; then
  FAIL=1
fi

if ! "$SCRIPT_DIR/validate-brief-inheritance.sh" "$BRIEF" ${PRED_ARGS[@]+"${PRED_ARGS[@]}"}; then
  FAIL=1
fi


# Bug-reproducer gate (#220 A2-1)
if ! "$SCRIPT_DIR/validate-brief.sh" "$BRIEF"; then
  FAIL=1
fi

exit "$FAIL"
