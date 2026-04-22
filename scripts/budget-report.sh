#!/usr/bin/env bash
# budget-report.sh — aggregate agent_session_completed events over the last N
# days and print a per-(agent, mode) roll-up: run count, p50/p95 tokens, seed
# budget, p95/budget ratio, cache_hit_rate, ctx_util_pct.
#
# Reads events from `resolve_events_dir()/YYYY-MM-DD.jsonl` (post-2.6 canonical
# root under ~/.dev-studio/<project>/events/). Emits
# a human-readable table to stdout. Intended to be wired into Chanakya's
# compact mode so the user sees the report on every sweep (see
# _shared/patterns/budget-telemetry.md).
#
# User is on the Claude Max plan (flat subscription). This report tracks
# consumption, not $. Prior $-denominated columns were dropped 2026-04-22 —
# see memory feedback_max_plan_pricing.md.
#
# Usage:
#   scripts/budget-report.sh              # last 7 days
#   scripts/budget-report.sh --days 30    # last N days
#   CTX_WINDOW_TOKENS=1000000 …           # override context-window baseline
#                                         # (default 200000 — standard Claude)

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

# Context-window baseline for ctx_util_pct. Standard Claude context is 200K;
# override via env for 1M-context sessions (e.g. Opus 4.7).
CTX_WINDOW_TOKENS=${CTX_WINDOW_TOKENS:-200000}

BUDGETS="$REPO_ROOT/_shared/schemas/token-budgets.json"
if ! command -v jq >/dev/null 2>&1; then
  printf 'budget-report: jq required\n' >&2
  exit 2
fi

events_dir=$(resolve_events_dir 2>/dev/null) || {
  printf 'budget-report: no project resolved — run from inside a project git repo\n' >&2
  exit 1
}
if [ ! -d "$events_dir" ]; then
  printf 'budget-report: no events dir at %s (empty report)\n' "$events_dir" >&2
  printf 'Budget report (last %d days)\n(no events)\n' "$DAYS"
  exit 0
fi

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

# Per-event TSV: agent, mode, input, output, cache_read.
tsv=$(mktemp)
printf '%s\n' "$files" | while IFS= read -r f; do
  [ -z "$f" ] && continue
  jq -r 'select(.event == "agent_session_completed") |
    [.agent,
     (.data.mode // ""),
     (.data.tokens.input // 0),
     (.data.tokens.output // 0),
     (.data.tokens.cache_read // 0)
    ] | @tsv' "$f" 2>/dev/null
done > "$tsv"

total_runs=$(wc -l < "$tsv" | tr -d ' ')
if [ "$total_runs" -eq 0 ]; then
  printf 'Budget report (last %d days)\n(no agent_session_completed events in window)\n' "$DAYS"
  rm -f "$tsv"
  exit 0
fi

# Aggregate per (agent, mode). Emit a header line of keys, then =DATA= marker,
# then per-run rows (so the second awk pass can sort tok_total for percentiles).
awk -F'\t' '
  {
    key = $1 "/" $2
    runs[key]++
    tok_total = $3 + $4
    sum_input[key] += $3
    sum_cache_read[key] += $5
    sum_ctx[key] += ($3 + $5)
  }
  END {
    for (k in runs) {
      print k "\t" runs[k] "\t" sum_input[k] "\t" sum_cache_read[k] "\t" sum_ctx[k]
    }
    print "=DATA="
  }
' "$tsv" > "${tsv}.agg"

# Per-run rows for percentile computation.
awk -F'\t' '{ print $1 "/" $2 "\t" ($3 + $4) }' "$tsv" >> "${tsv}.agg"

# Header.
printf 'Budget report (last %d days)\n' "$DAYS"
printf '%-10s %-18s %5s %9s %9s %8s %11s %10s %9s\n' \
  'Agent' 'Mode' 'Runs' 'p50 tok' 'p95 tok' 'Budget' 'p95/budget' 'cache_hit' 'ctx_util'

# Second pass: compute p50/p95 per key, join with sum_* for the derived columns.
awk -F'\t' -v ctx_window="$CTX_WINDOW_TOKENS" '
  BEGIN { data = 0 }
  $0 == "=DATA=" { data = 1; next }
  data == 0 {
    order[++n_keys] = $1
    key_runs[$1] = $2
    sum_input[$1] = $3
    sum_cache_read[$1] = $4
    sum_ctx[$1] = $5
    next
  }
  {
    toks[$1, ++toks_n[$1]] = $2
  }
  END {
    for (i = 1; i <= n_keys; i++) {
      key = order[i]
      n = toks_n[key]
      for (a = 1; a <= n; a++) {
        for (b = a + 1; b <= n; b++) {
          if (toks[key, a] > toks[key, b]) {
            t = toks[key, a]; toks[key, a] = toks[key, b]; toks[key, b] = t
          }
        }
      }
      idx50 = int(n * 0.5); if (idx50 < 1) idx50 = 1
      idx95 = int(n * 0.95); if (idx95 < 1) idx95 = 1
      p50 = toks[key, idx50]
      p95 = toks[key, idx95]
      # cache_hit_rate = cache_read / (cache_read + input); skip if no token data.
      denom = sum_cache_read[key] + sum_input[key]
      if (denom > 0) {
        hit = sum_cache_read[key] / denom
        hit_s = sprintf("%.2f", hit)
      } else {
        hit_s = "n/a"
      }
      # ctx_util_pct = mean((input + cache_read) / ctx_window) per run.
      if (ctx_window > 0 && n > 0) {
        util = (sum_ctx[key] / n) / ctx_window
        util_s = sprintf("%.2f", util)
      } else {
        util_s = "n/a"
      }
      split(key, ab, "/")
      print ab[1] "\t" ab[2] "\t" n "\t" p50 "\t" p95 "\t" hit_s "\t" util_s
    }
  }
' "${tsv}.agg" | sort | while IFS=$'\t' read -r agent mode runs p50 p95 hit util; do
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
  printf '%-10s %-18s %5s %9s %9s %8s %11s %10s %9s\n' \
    "$agent" "$mode" "$runs" "$p50" "$p95" "$budget" "$ratio" "$hit" "$util"
done

printf '\nTotal runs: %s   (ctx window baseline: %s tokens)\n' "$total_runs" "$CTX_WINDOW_TOKENS"

rm -f "$tsv" "${tsv}.agg"
