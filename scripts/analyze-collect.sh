#!/usr/bin/env bash
# analyze-collect.sh [--project <slug>] [--since <YYYY-MM-DD>]
#
# Gather mechanical stats for a usage-analysis pass (ANALYSIS.md). Prints to
# stdout — paste the output directly into today's analysis report, then add
# the human-judgment sections (patterns, public issues, "Wished I had").
#
# Reads the target project's event log, debriefs, reviews, and worker logs.
# Writes nothing. Defaults to the current project (from lib-paths.sh) and a
# 14-day window.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT=""
SINCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$PROJECT" ]; then
  if PROJECT=$(ACHILLES_PROJECT="" resolve_project 2>/dev/null); then :; else
    echo "error: no project resolved. Pass --project <slug> (e.g. turnip-ios)." >&2
    exit 1
  fi
fi

if [ -z "$SINCE" ]; then
  # 14 days back (portable date math: macOS = -v, GNU = -d)
  SINCE=$(date -u -v-14d +%Y-%m-%d 2>/dev/null || date -u -d '14 days ago' +%Y-%m-%d)
fi

# Resolve project-memory path by looking for the one matching slug. The slug
# scheme is <repo-toplevel-path>/ → '-'-separated; we can't reverse-derive
# without the actual repo path, so glob ~/.claude/projects/ for a match.
find_memory() {
  local name="$1" d
  for d in "$HOME"/.claude/projects/*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      *"-$name"|*"-${name}") printf '%s/memory\n' "$d"; return 0 ;;
    esac
  done
  return 1
}

MEMORY=$(find_memory "$PROJECT") || {
  echo "error: no project memory dir matched slug '$PROJECT' under ~/.claude/projects/" >&2
  echo "  Looked for a dir whose name ends in '-$PROJECT'." >&2
  exit 1
}

EVENT_DIR=$(resolve_events_dir_for "$PROJECT")
REVIEW_DIR="$MEMORY/reviews"
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
# Post-2.6: canonical debriefs live at plans/debriefs/*.yaml. Pre-2.6
# artifacts were archived as-is in plans/chanakya-inbox/processed/ per Q18
# — analysis tools walk both to preserve historical continuity.
DEBRIEFS_DIR_NEW="$PROJECT_ROOT/plans/debriefs"
DEBRIEFS_DIR_LEGACY="$PROJECT_ROOT/plans/chanakya-inbox/processed"
FLEET_ROOT=$(resolve_inbox_root_for "$PROJECT")
FEEDBACK_INBOX=$(resolve_feedback_inbox_for "$PROJECT")

echo "# analyze-collect: $PROJECT"
echo "window: $SINCE → $(date -u +%Y-%m-%d)"
echo "memory: $MEMORY"
echo

echo "## Feedback inbox (read these first — user-authored, highest signal)"
if [ -d "$FEEDBACK_INBOX" ]; then
  count=$(find "$FEEDBACK_INBOX" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "count: $count"
  if [ "$count" -gt 0 ]; then
    for f in "$FEEDBACK_INBOX"/*.md; do
      [ -f "$f" ] || continue
      kind=$(sed -n 's/^kind:[[:space:]]*//p' "$f" | head -1)
      sev=$(sed -n 's/^severity:[[:space:]]*//p' "$f" | head -1)
      echo "  - $(basename "$f")  [kind=${kind:-?} sev=${sev:-?}]"
    done
  fi
else
  echo "(no feedback inbox at $FEEDBACK_INBOX)"
fi
echo

# Day-partitioned filename check — YYYY-MM-DD.jsonl only. Skips pre-2.6
# siblings (events.jsonl, agents.jsonl) that share the post-2.6 events dir.
is_day_partition() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

stream_window_events() {
  local f d
  [ -d "$EVENT_DIR" ] || return 1
  for f in "$EVENT_DIR"/*.jsonl; do
    [ -f "$f" ] || continue
    d=$(basename "$f" .jsonl)
    is_day_partition "$d" || continue
    [ "$d" \< "$SINCE" ] && continue
    cat "$f"
  done
}

echo "## Event counts (by type)"
if [ -d "$EVENT_DIR" ]; then
  # JSONL filenames are YYYY-MM-DD.jsonl — lexicographic compare == date compare.
  out=$(
    stream_window_events | sed -n 's/.*"event":"\([^"]*\)".*/\1/p' | sort | uniq -c | sort -rn
  )
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    echo "(no events in window; earliest file = $(ls "$EVENT_DIR" 2>/dev/null | head -1 || echo none))"
  fi
else
  echo "(no event dir at $EVENT_DIR)"
fi
echo

echo "## Brief → dispatch latency"
if [ ! -d "$EVENT_DIR" ]; then
  echo "(no event dir at $EVENT_DIR)"
elif ! command -v jq >/dev/null 2>&1; then
  echo "unavailable: jq required to join brief and dispatch events"
else
  rows=$(
    stream_window_events | jq -r '
      def epoch: try (.ts | fromdateiso8601 | floor) catch "";
      def task_id: (.data.task_id // .data.legacy_task_id // .task // "");
      def to_state: (.data.to // .data.to_state // "");
      select(
        .event == "brief_written"
        or (.event == "brief_state_changed" and (to_state == "draft" or to_state == "ready"))
        or .event == "task_dispatched"
      )
      | [epoch, (.event // ""), task_id] | @tsv
    ' 2>/dev/null
  )
  if [ -z "$rows" ]; then
    echo "(no brief_written/brief_state_changed or task_dispatched events in window)"
  else
    printf '%s\n' "$rows" | awk -F'\t' -v now="$(date -u +%s)" '
      function valid_epoch(v) { return (v ~ /^[0-9]+$/ && v > 0) }
      function remember_task(t) {
        if (!(t in seen_task)) {
          seen_task[t] = 1
          task_order[++task_n] = t
        }
      }
      function add_latency(v,    n) {
        n = ++latency_n
        latency[n] = v
        latency_total += v
        if (v > latency_max) latency_max = v
      }
      function percentile(pct,    i,j,idx,tmp) {
        if (latency_n < 1) return "n/a"
        for (i = 1; i <= latency_n; i++) sorted[i] = latency[i]
        for (i = 1; i <= latency_n; i++) {
          for (j = i + 1; j <= latency_n; j++) {
            if (sorted[i] > sorted[j]) {
              tmp = sorted[i]; sorted[i] = sorted[j]; sorted[j] = tmp
            }
          }
        }
        idx = int(latency_n * pct + 0.999)
        if (idx < 1) idx = 1
        if (idx > latency_n) idx = latency_n
        return sorted[idx]
      }
      {
        epoch=$1; event=$2; task=$3
        if (!valid_epoch(epoch) || task == "") next
        if (event == "brief_written" || event == "brief_state_changed") {
          remember_task(task)
          if (write_at[task] == "" || epoch < write_at[task]) write_at[task] = epoch
        } else if (event == "task_dispatched") {
          if (dispatch_at[task] == "" || epoch < dispatch_at[task]) dispatch_at[task] = epoch
        }
      }
      END {
        for (i = 1; i <= task_n; i++) {
          task = task_order[i]
          written++
          if (dispatch_at[task] != "" && dispatch_at[task] >= write_at[task]) {
            dispatched++
            add_latency(dispatch_at[task] - write_at[task])
          } else if (dispatch_at[task] != "" && dispatch_at[task] < write_at[task]) {
            dispatch_before_write++
          } else {
            pending++
            age = now - write_at[task]
            if (age > oldest_pending_age) oldest_pending_age = age
            if (age >= 86400) pending_24h++
          }
        }
        avg = latency_n > 0 ? int(latency_total / latency_n) : "n/a"
        print "source: brief_written/brief_state_changed → task_dispatched (joined by task_id)"
        printf "written: %d\n", written + 0
        printf "dispatched: %d\n", dispatched + 0
        printf "pending: %d\n", pending + 0
        printf "dispatch_before_write: %d\n", dispatch_before_write + 0
        printf "latency_s: samples=%d avg=%s p50=%s p90=%s max=%s\n", latency_n + 0, avg, percentile(0.50), percentile(0.90), (latency_n > 0 ? latency_max : "n/a")
        printf "pending_age_s: oldest=%s over_24h=%d\n", (pending > 0 ? oldest_pending_age : "n/a"), pending_24h + 0
      }
    '
  fi
fi
echo

echo "## Review verdict rates"
# Source of truth: Argus-emitted verdict events in the event log. Approved
# approved reviews aren't persisted as files, so any
# file-scan count is structurally incomplete — #21. File-scan stays as a
# sanity cross-check for flagged/blocked; drift surfaces via reconcile lines.
count_verdict_events() {
  local verdict="$1" f d
  [ -d "$EVENT_DIR" ] || { echo 0; return; }
  for f in "$EVENT_DIR"/*.jsonl; do
    [ -f "$f" ] || continue
    d=$(basename "$f" .jsonl)
    # Skip pre-2.6 siblings (events.jsonl, agents.jsonl) and out-of-window days.
    is_day_partition "$d" || continue
    [ "$d" \< "$SINCE" ] && continue
    cat "$f"
  done | grep -F "\"event\":\"review_${verdict}\"" \
       | grep -F "\"agent\":\"argus\"" \
       | wc -l | tr -d ' '
}

# File-scan cross-check. Hardened regex accepts plain `Verdict: x`, bold
# `**Verdict:** x`, and lowercase variants (#21). Approved files are usually
# absent (argus skips them), so the approved cross-check is expected to lag.
# Two anchored alternatives rather than one loose pattern — keeps the match
# tight (requires a colon) while accepting both styles we see in practice.
count_verdict_files() {
  local verdict="$1"
  [ -d "$REVIEW_DIR" ] || { echo 0; return; }
  grep -lEi "^[[:space:]]*(verdict:|\*\*verdict:\*\*)[[:space:]]+$verdict" \
    "$REVIEW_DIR"/*.md "$REVIEW_DIR"/archive/*.md 2>/dev/null \
    | wc -l | tr -d ' '
}

ev_approved=$(count_verdict_events approved)
ev_flagged=$(count_verdict_events flagged)
ev_blocked=$(count_verdict_events blocked)
fs_approved=$(count_verdict_files approved)
fs_flagged=$(count_verdict_files flagged)
fs_blocked=$(count_verdict_files blocked)

echo "source: event log (argus-emitted, canonical)"
echo "approved: $ev_approved"
echo "flagged:  $ev_flagged"
echo "blocked:  $ev_blocked"
echo
echo "cross-check: filesystem ($REVIEW_DIR)"
echo "approved: $fs_approved  (expected ≤ event count; argus rarely writes approved files)"
echo "flagged:  $fs_flagged"
echo "blocked:  $fs_blocked"

# Reconcile. Event log wins; surface drift rather than hide it. Approved is
# one-sided (file ≤ events is normal); flagged/blocked should match closely.
reconcile=""
[ "$fs_approved" -gt "$ev_approved" ] && reconcile="${reconcile}approved fs>ev (${fs_approved} vs ${ev_approved}); "
[ "$fs_flagged" != "$ev_flagged" ] && reconcile="${reconcile}flagged drift (ev=${ev_flagged} fs=${fs_flagged}); "
[ "$fs_blocked" != "$ev_blocked" ] && reconcile="${reconcile}blocked drift (ev=${ev_blocked} fs=${fs_blocked}); "
if [ -n "$reconcile" ]; then
  echo
  echo "reconcile: ${reconcile%; }"
  echo "  (event log is authoritative; investigate if flagged/blocked diverge materially)"
fi
echo

echo "## Debriefs processed"
new_count=0
legacy_count=0
[ -d "$DEBRIEFS_DIR_NEW" ] && \
  new_count=$(find "$DEBRIEFS_DIR_NEW" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null | wc -l | tr -d ' ')
[ -d "$DEBRIEFS_DIR_LEGACY" ] && \
  legacy_count=$(find "$DEBRIEFS_DIR_LEGACY" -name '*-debrief.md' -type f 2>/dev/null | wc -l | tr -d ' ')
total=$(( new_count + legacy_count ))
if [ "$total" -eq 0 ]; then
  echo "(no debriefs under $DEBRIEFS_DIR_NEW or $DEBRIEFS_DIR_LEGACY)"
else
  echo "count: $total (canonical=$new_count legacy=$legacy_count)"
  echo "most recent:"
  # Union both dirs, sort by mtime, show top 5.
  {
    [ -d "$DEBRIEFS_DIR_NEW" ] && find "$DEBRIEFS_DIR_NEW" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null
    [ -d "$DEBRIEFS_DIR_LEGACY" ] && find "$DEBRIEFS_DIR_LEGACY" -name '*-debrief.md' -type f 2>/dev/null
  } | xargs ls -lt 2>/dev/null | head -5 | awk '{print "  "$NF}'
fi
echo

echo "## Worker activity"
if [ -d "$FLEET_ROOT" ]; then
  for d in "$FLEET_ROOT"/worker-*/; do
    [ -d "$d" ] || continue
    N=$(basename "$d" | sed 's/worker-//')
    done_ct=$(find "$d/done" -name '*.task' 2>/dev/null | wc -l | tr -d ' ')
    rescue_ct=$(find "$d/rescue" -name '*.task' 2>/dev/null | wc -l | tr -d ' ')
    echo "worker-$N: done=$done_ct rescue=$rescue_ct"
  done
else
  echo "(no fleet root at $FLEET_ROOT)"
fi
echo

echo "## Next steps"
echo "- Read the debriefs' 'Key Learnings' + 'Blockers' sections for patterns."
echo "- Diff the flag/block counts by rule (grep review files for 'rule:' frontmatter)."
echo "- Fill in the template sections in ~/.dev-studio/$PROJECT/analysis/$(date -u +%Y-%m-%d).md"
echo "- Keep the '## Wished I had' section first-class — that's what feeds #11."
