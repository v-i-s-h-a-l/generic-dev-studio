#!/usr/bin/env bash
# status-render-tasks.sh — stdin JSON → markdown task table.
#
# Accepts a briefs snapshot payload (or fallback-equivalent). Prints a markdown
# table of active tasks with Priority / Status / Complexity / Branch columns.
# Briefed / in-progress rows with a populated `summary` field get a continuation
# line carrying the compact brief slice.
#
# Input shape (minimum fields on each task): id, title, priority, status,
# complexity, branch. Optional: summary, blocked_by_predecessor,
# cascading_block. Extra fields are ignored.

set -u
umask 022

payload=$(cat)
if [ -z "$payload" ]; then
  printf 'No tasks.\n'
  exit 0
fi

count=$(printf '%s' "$payload" | jq -r '.tasks | length // 0' 2>/dev/null)
if [ -z "$count" ] || [ "$count" = "0" ] || [ "$count" = "null" ]; then
  printf 'No active tasks.\n'
  exit 0
fi

printf '| ID   | Title                                    | Priority | Status      | Complexity | Branch          |\n'
printf '|------|------------------------------------------|----------|-------------|------------|-----------------|\n'
printf '%s' "$payload" | jq -r '
  .tasks[] |
  def clean_summary:
    (.summary // "")
    | gsub("[\r\n\t]+"; " ")
    | gsub("  +"; " ")
    | sub("^ +"; "")
    | sub(" +$"; "");
  def dag_annotation:
    ([select(((.blocked_by_predecessor // []) | length) > 0)
      | "blocked_by_predecessor=" + ((.blocked_by_predecessor // []) | join(","))]
     + [select(.cascading_block == true) | "cascading_block=true"])
    | join(" ");
  (
    "| \(.id // "—") | \(.title // "—" | .[0:40]) | \(.priority // "—") | \(.status // "—") | \(.complexity // "—") | \(.branch // "—") |"
  ),
  (
    select((.status == "briefed" or .status == "in-progress") and (clean_summary != ""))
    | "  └─ \(clean_summary)"
  ),
  (
    select(dag_annotation != "")
    | "  └─ \(dag_annotation)"
  )
'
