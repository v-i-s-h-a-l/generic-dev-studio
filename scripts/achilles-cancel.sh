#!/usr/bin/env bash
# achilles-cancel.sh <task-id>
# Removes pending task files matching the id from every worker inbox in
# the current project's fleet. Cross-project: set ACHILLES_PROJECT=<slug>.
# Cannot stop an in-flight task — kill the worker pane manually for that.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

TASK_ID="${1:?usage: achilles-cancel.sh <task-id>}"
ROOT=$(resolve_inbox_root) || exit 1

removed=0
shopt -s nullglob
for f in "$ROOT"/worker-*/inbox/*-"${TASK_ID}".task; do
  rm "$f"
  echo "cancelled $f"
  removed=$((removed+1))
done
if [ "$removed" -eq 0 ]; then
  echo "no pending task file matched $TASK_ID in $ROOT (already in-flight or completed?)" >&2
  exit 1
fi
