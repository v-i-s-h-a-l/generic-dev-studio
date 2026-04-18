#!/usr/bin/env bash
# achilles-cancel.sh <task-id>
# Removes pending task files matching the id from every worker inbox.
# Cannot stop an in-flight task — kill the worker pane manually for that.
set -euo pipefail
TASK_ID="${1:?usage: achilles-cancel.sh <task-id>}"
ROOT="${ACHILLES_INBOX_ROOT:-$HOME/.dev-studio/.runtime/achilles-inbox}"
removed=0
shopt -s nullglob
for f in "$ROOT"/worker-*/inbox/*-"${TASK_ID}".task; do
  rm "$f"
  echo "cancelled $f"
  removed=$((removed+1))
done
if [ "$removed" -eq 0 ]; then
  echo "no pending task file matched $TASK_ID (already in-flight or completed?)" >&2
  exit 1
fi
