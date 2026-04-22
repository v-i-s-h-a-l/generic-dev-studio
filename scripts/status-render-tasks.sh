#!/usr/bin/env bash
# status-render-tasks.sh — stdin JSON → markdown task table.
#
# Accepts a briefs snapshot payload (or fallback-equivalent). Prints a markdown
# table of active tasks with Priority / Status / Complexity / Branch columns.
# `done` rows are prefixed with an asterisk so the caller can annotate
# "awaiting verification" in prose.
#
# Input shape (minimum fields on each task): id, title, priority, status,
# complexity, branch. Extra fields are ignored.

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
  "| \(.id // "—") | \(.title // "—" | .[0:40]) | \(.priority // "—") | \(.status // "—") | \(.complexity // "—") | \(.branch // "—") |"
'
