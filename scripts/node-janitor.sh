#!/usr/bin/env bash
# node-janitor.sh — periodic remote-node disk sweep (#129).
#
# Runs on every worker node (and on dual-role laptops) via a LaunchAgent
# scheduled at StartInterval=21600 (every 6h). Sweeps direct children of
# `~/.dev-studio/.runtime/derived-data/` and `~/.dev-studio/.runtime/worktrees/`
# whose mtime is older than --days N (default 3). Anything newer is treated
# as in-flight and left alone.
#
# Path safety: only direct children (`-mindepth 1 -maxdepth 1 -type d`) of the
# two hard-coded roots get removed. The roots resolve through lib-paths.sh —
# no caller-controlled path crosses into rm.
#
# Usage:
#   scripts/node-janitor.sh [--days N] [--dry-run] [--quiet]
#
# Exit codes:
#   0  swept (or nothing to do)
#   2  bad args
#
# Telemetry: appends one line per run to ~/.dev-studio/.runtime/node-janitor.log.
# Rotates at 1 MB to <log>.1. Event log is project-scoped; the janitor has no
# project context on a worker, so it deliberately does not emit_event_keyed.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# REVIEW R3 carve-out: workers receive only the runtime-bin copy of this
# script, not the full studio repo, so lib-paths.sh isn't reliably sourceable.
# resolve_runtime_global() is a one-line formula; inline it here and keep this
# the only literal `$HOME/.dev-studio/.runtime` outside lib-paths.sh + the
# matching note in node-dispatch.sh.
runtime_global_dir() { printf '%s\n' "$HOME/.dev-studio/.runtime"; }

DAYS=3
DRY_RUN=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --days)    DAYS="${2:?--days requires N}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet)   QUIET=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) printf 'node-janitor: unknown flag %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$DAYS" in
  ''|*[!0-9]*) printf 'node-janitor: --days must be a non-negative integer (got %s)\n' "$DAYS" >&2; exit 2 ;;
esac

RUNTIME=$(runtime_global_dir)
LOG="$RUNTIME/node-janitor.log"
ROOTS=("$RUNTIME/derived-data" "$RUNTIME/worktrees")

mkdir -p "$RUNTIME" 2>/dev/null || true

# Rotate at 1 MB. Single backup; older content discarded — telemetry, not audit.
if [ -f "$LOG" ]; then
  size=$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]')
  if [ "${size:-0}" -gt 1048576 ]; then
    mv "$LOG" "$LOG.1" 2>/dev/null || true
  fi
fi

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
swept=0
freed_kb=0

for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  # find guarantees direct children only; -mtime +N is "older than N*24h ago".
  while IFS= read -r victim; do
    [ -n "$victim" ] || continue
    case "$victim" in
      "$root"/*) ;;
      *) continue ;;  # defense-in-depth — find should never emit anything else
    esac
    kb=$(du -sk "$victim" 2>/dev/null | awk '{print $1}')
    kb=${kb:-0}
    if [ "$DRY_RUN" -eq 1 ]; then
      [ "$QUIET" -eq 1 ] || printf 'node-janitor: DRY-RUN rm -rf %s (%s KB)\n' "$victim" "$kb"
    else
      if rm -rf -- "$victim" 2>/dev/null; then
        swept=$((swept + 1))
        freed_kb=$((freed_kb + kb))
        [ "$QUIET" -eq 1 ] || printf 'node-janitor: removed %s (%s KB)\n' "$victim" "$kb"
      else
        printf 'node-janitor: warn: rm failed on %s\n' "$victim" >&2
      fi
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -mtime "+$DAYS" 2>/dev/null)
done

# Single-line telemetry — small, append-only, easily grep'd from the laptop
# via `ssh node tail -F ~/.dev-studio/.runtime/node-janitor.log`.
mode="apply"
[ "$DRY_RUN" -eq 1 ] && mode="dry-run"
printf '{"ts":"%s","mode":"%s","days":%s,"swept":%s,"freed_kb":%s}\n' \
  "$ts" "$mode" "$DAYS" "$swept" "$freed_kb" >> "$LOG" 2>/dev/null || true

[ "$QUIET" -eq 1 ] || printf 'node-janitor: %s — swept %s dir(s), freed ~%s KB (days=%s)\n' \
  "$mode" "$swept" "$freed_kb" "$DAYS"

exit 0
