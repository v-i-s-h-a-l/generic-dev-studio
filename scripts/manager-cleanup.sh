#!/usr/bin/env bash
# manager-cleanup.sh — user-facing cleanup front-end.
#
# Today this surface owns one subcommand: `--worktrees`, which delegates to
# scripts/studio-worktree-gc.sh and prints a friendly summary. It is the
# command the worktree disk-budget alarm points the user at (layer 3 of the
# cleanup contract in _shared/contracts/worktree-marker.md).
#
# Usage:
#   scripts/manager-cleanup.sh --worktrees [--project <slug>] [--ttl-days N]
#                                          [--active-ids <csv>] [--keep <csv>]
#                                          [--dry-run] [--reap-stale]
#                                          [--budget-check] [--json]
#
# By default `--worktrees` runs `studio-worktree-gc.sh --budget-check` plus
# `--reap-stale` to do the same thing the user would do interactively after
# the budget alarm fires. Pass `--dry-run` to inspect first.
#
# Exit codes:
#   0  cleanup completed (nothing to reap, or reap succeeded)
#   2  invalid usage
#   3  reap attempted but at least one worktree failed to remove
#   4  unknown subcommand

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

usage() {
  sed -n '2,22p' "$0"
}

SUBCOMMAND=""
declare -a PASSTHRU=()
DRY_RUN=0
JSON_OUT=0
DO_BUDGET=1
DO_REAP=1

while [ $# -gt 0 ]; do
  case "$1" in
    --worktrees) SUBCOMMAND="worktrees"; shift ;;
    --project|--ttl-days|--active-ids|--keep)
      PASSTHRU+=("$1" "${2:-}"); shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --reap-stale)  DO_REAP=1; shift ;;
    --no-reap)     DO_REAP=0; shift ;;
    --budget-check) DO_BUDGET=1; shift ;;
    --no-budget-check) DO_BUDGET=0; shift ;;
    --json)        JSON_OUT=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) printf 'manager-cleanup.sh: unknown flag %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$SUBCOMMAND" ]; then
  printf 'manager-cleanup.sh: pick a target (--worktrees today)\n' >&2
  usage >&2
  exit 2
fi

case "$SUBCOMMAND" in
  worktrees)
    declare -a GC_ARGS=("${PASSTHRU[@]:-}")
    [ "$DO_BUDGET" = "1" ] && GC_ARGS+=("--budget-check")
    [ "$DO_REAP" = "1" ] && GC_ARGS+=("--reap-stale")
    [ "$DRY_RUN" = "1" ] && GC_ARGS+=("--dry-run")

    REPORT=$("$SCRIPT_DIR/studio-worktree-gc.sh" "${GC_ARGS[@]}")
    rc=$?

    if [ "$JSON_OUT" = "1" ]; then
      printf '%s\n' "$REPORT"
      exit "$rc"
    fi

    # Human summary on stderr; the structured report still goes to stdout if
    # the user wanted it (but we omit by default — the prose summary is enough
    # for the cleanup flow).
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$REPORT" | jq -r '
        "worktrees: \(.totals.worktrees)  size: \(.totals.bytes)B  reapable: \(.totals.reapable)  reaped: \(.totals.reaped)",
        "budget: \(.budget.status)\(if .budget.reason != "" then " (\(.budget.reason))" else "" end)",
        (.entries[]
          | select(.status != "fresh")
          | "  \(.status)\t\(.slug)\tage=\(.age_seconds)s\treason=\(.reason)")
      '
    else
      # Fallback: just echo the JSON if jq is unavailable. Users who care can
      # parse it; the budget alarm warning has already been printed to stderr
      # by studio-worktree-gc.sh.
      printf '%s\n' "$REPORT"
    fi

    exit "$rc"
    ;;
  *)
    printf 'manager-cleanup.sh: unknown subcommand %s\n' "$SUBCOMMAND" >&2
    exit 4
    ;;
esac
