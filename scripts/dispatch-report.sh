#!/usr/bin/env bash
# dispatch-report.sh — N-day digest of dispatch decisions.
#
# Reads the per-project event log (resolve_events_dir) for the last N
# days and prints a human-readable summary: per-node build counts, avg
# duration, fallback rate, and top failure causes. The data source is
# `studio.dispatch.*`-tagged build_check_* / test_run_* events plus the
# discriminating node_fallback / node_unreachable events from #137.
#
# Usage:
#   scripts/dispatch-report.sh [<days>]
#     days: number of trailing days to include (default 7; max 90)
#
# Exit codes:
#   0  report printed
#   2  bad args / events dir unreadable / jq missing

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

DAYS="${1:-7}"
case "$DAYS" in
  ''|*[!0-9]*) printf 'error: days must be a positive integer (got %s)\n' "$DAYS" >&2; exit 2 ;;
esac
[ "$DAYS" -ge 1 ] || { printf 'error: days must be >= 1\n' >&2; exit 2; }
[ "$DAYS" -le 90 ] || DAYS=90

command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }

EVENTS_DIR=$(resolve_events_dir 2>/dev/null) || {
  printf 'error: cannot resolve events directory\n' >&2; exit 2
}
[ -d "$EVENTS_DIR" ] || { printf 'error: %s is not a directory\n' "$EVENTS_DIR" >&2; exit 2; }

# Build the list of files to read — last N calendar days. macOS `date -v`
# and GNU `date -d` differ; try both.
files=""
i=0
while [ "$i" -lt "$DAYS" ]; do
  if d=$(date -u -v-"${i}"d +%Y-%m-%d 2>/dev/null); then :; else
    d=$(date -u -d "$i days ago" +%Y-%m-%d 2>/dev/null) || d=""
  fi
  [ -z "$d" ] && break
  f="$EVENTS_DIR/$d.jsonl"
  [ -r "$f" ] && files="$files $f"
  i=$((i + 1))
done

if [ -z "$files" ]; then
  printf 'No event logs found in last %s days under %s\n' "$DAYS" "$EVENTS_DIR"
  exit 0
fi

# shellcheck disable=SC2086
total=$(cat $files 2>/dev/null | wc -l | tr -d ' ')

printf '\n=== Dispatch report — last %s day(s), %s events scanned ===\n' "$DAYS" "$total"
printf 'Source: %s\n\n' "$EVENTS_DIR"

# --- Per-node build counts + avg duration (full-green build_check_passed only).
# Duration: matched start↔terminal pairs aren't joined here — too expensive
# for a one-shot script. Instead, use the duration-equivalent surfaced by
# gate-announce (locked_out's waited_s, etc). Where unavailable we count
# events only.
printf '## Per-node build_check counts (full-green + swift-test)\n\n'
# shellcheck disable=SC2086
cat $files 2>/dev/null \
  | jq -r 'select(.event=="build_check_passed" or .event=="build_check_failed")
           | .data["studio.dispatch.node"] // .data.node // "unknown"
           | tostring' 2>/dev/null \
  | sort | uniq -c | sort -rn \
  | awk 'BEGIN{printf "  %-20s %s\n", "node", "count"; printf "  %-20s %s\n", "----", "-----"} {printf "  %-20s %s\n", $2, $1}'

printf '\n## Per-node test_run counts\n\n'
# shellcheck disable=SC2086
cat $files 2>/dev/null \
  | jq -r 'select(.event=="test_run_passed" or .event=="test_run_failed")
           | .data["studio.dispatch.node"] // .data.node // "unknown"
           | tostring' 2>/dev/null \
  | sort | uniq -c | sort -rn \
  | awk 'BEGIN{printf "  %-20s %s\n", "node", "count"; printf "  %-20s %s\n", "----", "-----"} {printf "  %-20s %s\n", $2, $1}'

# --- Fallback rate. Numerator: node_fallback events. Denominator: total
# dispatch decisions (build_check_started + test_run_started where the
# studio.dispatch.* tags exist — i.e. full-green / swift-test, not lsp).
printf '\n## Fallback rate\n\n'
fb_total=0
disp_total=0
# shellcheck disable=SC2086
fb_total=$(cat $files 2>/dev/null \
  | jq -r 'select(.event=="node_fallback") | 1' 2>/dev/null | wc -l | tr -d ' ')
# shellcheck disable=SC2086
disp_total=$(cat $files 2>/dev/null \
  | jq -r 'select((.event=="build_check_started" or .event=="test_run_started")
                  and (.data["studio.dispatch.role"] != null)) | 1' 2>/dev/null | wc -l | tr -d ' ')
if [ "$disp_total" -gt 0 ]; then
  pct=$(awk -v n="$fb_total" -v d="$disp_total" 'BEGIN{printf "%.1f", (n/d)*100}')
  printf '  %s / %s decisions (%s%%) fell back to local\n' "$fb_total" "$disp_total" "$pct"
else
  printf '  no tagged dispatch decisions in window\n'
fi

# --- Fallback reasons (top 10).
printf '\n## Fallback reasons\n\n'
# shellcheck disable=SC2086
cat $files 2>/dev/null \
  | jq -r 'select(.event=="node_fallback")
           | "\(.data["studio.dispatch.reason"] // "unknown")\t\(.data["studio.dispatch.role"] // "")"' 2>/dev/null \
  | sort | uniq -c | sort -rn | head -10 \
  | awk 'BEGIN{printf "  %-28s %-12s %s\n", "reason", "role", "count"; printf "  %-28s %-12s %s\n", "------", "----", "-----"}
         {n=$1; $1=""; sub(/^ +/,""); split($0, p, "\t"); printf "  %-28s %-12s %s\n", p[1], p[2], n}'

# --- Unreachable per node (top 10) + first error excerpt.
printf '\n## Unreachable probes\n\n'
# shellcheck disable=SC2086
cat $files 2>/dev/null \
  | jq -r 'select(.event=="node_unreachable")
           | "\(.data["studio.dispatch.node"] // "unknown")\t\(.data["studio.dispatch.probe"] // "")"' 2>/dev/null \
  | sort | uniq -c | sort -rn | head -10 \
  | awk 'BEGIN{printf "  %-20s %-10s %s\n", "node", "probe", "count"; printf "  %-20s %-10s %s\n", "----", "-----", "-----"}
         {n=$1; $1=""; sub(/^ +/,""); split($0, p, "\t"); printf "  %-20s %-10s %s\n", p[1], p[2], n}'

# --- Build-queue depth distribution (#266). Every full-green gate emits
# one build_queue_position at enqueue with depth + position. Surface the
# count of queued runs per node and the share that hit non-trivial waits
# (position > 1) so saturation is visible without running query-events.
printf '\n## Build-queue enqueues (full-green only)\n\n'
# shellcheck disable=SC2086
queue_total=$(cat $files 2>/dev/null \
  | jq -r 'select(.event=="build_queue_position") | 1' 2>/dev/null | wc -l | tr -d ' ')
if [ "$queue_total" -gt 0 ]; then
  printf '  %-20s %-10s %-12s %s\n' "node" "enqueues" "waited(>1)" "max_depth"
  printf '  %-20s %-10s %-12s %s\n' "----" "--------" "----------" "---------"
  # shellcheck disable=SC2086
  cat $files 2>/dev/null \
    | jq -r 'select(.event=="build_queue_position")
             | "\(.data.node // "unknown")\t\(.data.position // 1)\t\(.data.depth // 1)"' 2>/dev/null \
    | awk -F'\t' '
        { n[$1]++; if ($2+0 > 1) waited[$1]++; if ($3+0 > maxd[$1]) maxd[$1] = $3+0 }
        END {
          for (k in n) {
            w = waited[k] + 0
            printf "  %-20s %-10s %-12s %s\n", k, n[k], w, maxd[k]
          }
        }' | sort -k2 -rn
else
  printf '  no build_queue_position events in window\n'
fi

# --- Dispatch harvests (#271). Each `dispatch_harvested` is a session that
# would have re-run a build/test on the worker but reused a prior dispatch's
# result instead — the user-visible reconnect-and-harvest win. Surface
# count per node + the harvested exit-code split so saturation of the
# resumable-dispatch path is visible without `query-events`.
printf '\n## Dispatch harvests (reconnect-and-harvest, #271)\n\n'
# shellcheck disable=SC2086
harvest_total=$(cat $files 2>/dev/null \
  | jq -r 'select(.event=="dispatch_harvested") | 1' 2>/dev/null | wc -l | tr -d ' ')
if [ "$harvest_total" -gt 0 ]; then
  printf '  %-20s %-10s %-10s %s\n' "node" "harvests" "rc=0" "rc!=0"
  printf '  %-20s %-10s %-10s %s\n' "----" "--------" "----" "-----"
  # shellcheck disable=SC2086
  cat $files 2>/dev/null \
    | jq -r 'select(.event=="dispatch_harvested")
             | "\(.data.node // "unknown")\t\(.data.exit_code // 0)"' 2>/dev/null \
    | awk -F'\t' '
        { n[$1]++; if ($2+0 == 0) green[$1]++; else red[$1]++ }
        END {
          for (k in n) {
            g = green[k] + 0; r = red[k] + 0
            printf "  %-20s %-10s %-10s %s\n", k, n[k], g, r
          }
        }' | sort -k2 -rn
else
  printf '  no dispatch_harvested events in window\n'
fi

# --- Top failure reasons on build_check_failed (the "what's actually
# breaking" view, complementary to fallback).
printf '\n## Top build_check_failed reasons\n\n'
# shellcheck disable=SC2086
cat $files 2>/dev/null \
  | jq -r 'select(.event=="build_check_failed")
           | (.data.reason // "build_error")' 2>/dev/null \
  | sort | uniq -c | sort -rn | head -10 \
  | awk 'BEGIN{printf "  %-28s %s\n", "reason", "count"; printf "  %-28s %s\n", "------", "-----"} {printf "  %-28s %s\n", $2, $1}'

printf '\n=== End report ===\n\n'
