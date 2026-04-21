#!/usr/bin/env bash
# budget-report.sh — aggregate agent_session_completed events over the last N
# days and print a per-(agent, mode) roll-up: run count, p50/p95 tokens, seed
# budget, p95/budget ratio, total spend.
#
# Reads events from `resolve_project_memory()/events/YYYY-MM-DD.jsonl`. Emits
# a human-readable table to stdout. Intended to be wired into Chanakya's
# compact mode so the user sees the report on every sweep (see
# _shared/patterns/budget-telemetry.md).
#
# Usage:
#   scripts/budget-report.sh           # last 7 days
#   scripts/budget-report.sh --days 30 # last N days

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

DAYS=7
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    *) printf 'usage: budget-report.sh [--days N]\n' >&2; exit 2 ;;
  esac
done

BUDGETS="$REPO_ROOT/_shared/schemas/token-budgets.json"
if ! command -v jq >/dev/null 2>&1; then
  printf 'budget-report: jq required\n' >&2
  exit 2
fi

memory=$(resolve_project_memory 2>/dev/null) || {
  printf 'budget-report: no project memory resolved — run from inside a project git repo\n' >&2
  exit 1
}
events_dir="$memory/events"
if [ ! -d "$events_dir" ]; then
  printf 'budget-report: no events dir at %s (empty report)\n' "$events_dir" >&2
  printf 'Budget report (last %d days)\n(no events)\n' "$DAYS"
  exit 0
fi

# Build the date list of files to scan (last N days, lexicographic sort).
now_epoch=$(date -u +%s)
files=""
for i in $(seq 0 $((DAYS - 1))); do
  day_epoch=$((now_epoch - i * 86400))
  day_s=$(date -u -r "$day_epoch" +%Y-%m-%d 2>/dev/null || date -u -d "@$day_epoch" +%Y-%m-%d)
  f="$events_dir/$day_s.jsonl"
  [ -f "$f" ] && files="${files}${files:+$'\n'}$f"
done

if [ -z "$files" ]; then
  printf 'Budget report (last %d days)\n(no events in window)\n' "$DAYS"
  exit 0
fi

# Extract every agent_session_completed event's (agent, mode, tokens_total,
# cost_usd) tuple as newline-separated TSV rows.
tsv=$(mktemp)
printf '%s\n' "$files" | while IFS= read -r f; do
  [ -z "$f" ] && continue
  jq -r 'select(.event == "agent_session_completed") |
    [.agent,
     (.data.mode // ""),
     ((.data.tokens.input // 0) + (.data.tokens.output // 0)),
     (.data.cost_usd // 0)
    ] | @tsv' "$f" 2>/dev/null
done > "$tsv"

total_runs=$(wc -l < "$tsv" | tr -d ' ')
if [ "$total_runs" -eq 0 ]; then
  printf 'Budget report (last %d days)\n(no agent_session_completed events in window)\n' "$DAYS"
  rm -f "$tsv"
  exit 0
fi

# Group by (agent, mode) and compute p50 / p95 / sum(cost). Emit human
# table. Awk handles the grouping; sort drives the percentile math.
awk -F'\t' -v budgets="$BUDGETS" '
  function percentile(arr, n, p,    idx) {
    idx = int(n * p / 100)
    if (idx < 1) idx = 1
    if (idx > n) idx = n
    return arr[idx]
  }
  BEGIN {
    # Lazy-load budgets via a jq sidecar would be ideal; done externally below.
  }
  {
    key = $1 "/" $2
    runs[key]++
    tok[key, runs[key]] = $3
    cost_sum[key] += $4
  }
  END {
    # Print the keys so the outer shell can join budget values.
    for (k in runs) print k "\t" runs[k]
    print "=DATA="
    for (k in runs) {
      n = runs[k]
      for (i = 1; i <= n; i++) {
        print k "\t" tok[k, i] "\t" cost_sum[k]
      }
    }
  }
' "$tsv" > "${tsv}.grouped"

# Extract budget for each (agent/mode) and build the final report.
printf 'Budget report (last %d days)\n' "$DAYS"
printf '%-10s %-18s %5s %9s %9s %8s %11s %8s\n' \
  'Agent' 'Mode' 'Runs' 'p50 tok' 'p95 tok' 'Budget' 'p95/budget' '$spent'

# Rebuild: read the grouped file; per key, gather tokens, compute p50/p95.
awk -F'\t' -v budgets="$BUDGETS" '
  function min(a, b) { return a < b ? a : b }
  BEGIN { data = 0 }
  $0 == "=DATA=" { data = 1; next }
  data == 0 {
    # Keys phase: remember order.
    order[++n_keys] = $1
    key_runs[$1] = $2
    next
  }
  # Data phase.
  {
    toks[$1, ++toks_n[$1]] = $2
    cost[$1] = $3
  }
  END {
    for (i = 1; i <= n_keys; i++) {
      key = order[i]
      n = toks_n[key]
      # Bubble-sort the per-key array (n is tiny — <500 runs typical).
      for (a = 1; a <= n; a++) {
        for (b = a+1; b <= n; b++) {
          if (toks[key, a] > toks[key, b]) {
            t = toks[key, a]; toks[key, a] = toks[key, b]; toks[key, b] = t
          }
        }
      }
      # Percentiles.
      idx50 = int(n * 0.5); if (idx50 < 1) idx50 = 1
      idx95 = int(n * 0.95); if (idx95 < 1) idx95 = 1
      p50 = toks[key, idx50]
      p95 = toks[key, idx95]
      split(key, ab, "/")
      print ab[1] "\t" ab[2] "\t" n "\t" p50 "\t" p95 "\t" cost[key]
    }
  }
' "${tsv}.grouped" | sort | while IFS=$'\t' read -r agent mode runs p50 p95 total_cost; do
  if [ -n "$mode" ] && [ "$mode" != "" ]; then
    budget=$(jq -r --arg k "$agent/$mode" '.mode_budgets[$k] // .default_mode_budget' "$BUDGETS" 2>/dev/null)
  else
    budget=$(jq -r --arg k "$agent" '.router_budgets[$k] // .default_router_budget' "$BUDGETS" 2>/dev/null)
  fi
  [ -z "$budget" ] && budget=0
  if [ "$budget" -gt 0 ]; then
    ratio=$(awk -v p="$p95" -v b="$budget" 'BEGIN { printf "%.2f", p / b }')
  else
    ratio="n/a"
  fi
  printf '%-10s %-18s %5s %9s %9s %8s %11s %8.2f\n' \
    "$agent" "$mode" "$runs" "$p50" "$p95" "$budget" "$ratio" "$total_cost" \
    2>/dev/null || \
  printf '%-10s %-18s %5s %9s %9s %8s %11s %8s\n' \
    "$agent" "$mode" "$runs" "$p50" "$p95" "$budget" "$ratio" "$total_cost"
done

total_spend=$(awk -F'\t' 'NF >= 6 { sum += $6 } END { printf "%.2f", sum }' "${tsv}.grouped" 2>/dev/null)
printf '\nTotal runs: %s   Total spend: $%s\n' "$total_runs" "${total_spend:-0.00}"

rm -f "$tsv" "${tsv}.grouped"
