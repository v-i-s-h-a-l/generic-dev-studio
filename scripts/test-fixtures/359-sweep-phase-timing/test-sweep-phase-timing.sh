#!/usr/bin/env bash
# Verifies sweep phase timing emits for a successful phase and a no-op phase.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t sweep-phase-timing.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT="sweep-phase-timing"

# shellcheck source=../../../lib-paths.sh
. "$ROOT/scripts/lib-paths.sh"

project_root=$(resolve_project_root_for "$ACHILLES_PROJECT")
events_dir=$(resolve_events_dir_for "$ACHILLES_PROJECT")
mkdir -p "$project_root/feedback" "$events_dir"

cat > "$project_root/feedback/active.md" <<'MD'
# Feedback

## Reminders
| due_at | type | args | description |
| --- | --- | --- | --- |
| 2020-01-01T00:00:00Z | ingest-reminder | --source test | fixture reminder |
| <!-- malformed --> | ingest-reminder | --source test | should stay |
MD

"$ROOT/scripts/sweep-feedback-reminders.sh"

log="$events_dir/$(date -u +%Y-%m-%d).jsonl"
jq -e 'select(.event=="feedback_reminder_due")' "$log" >/dev/null
jq -e 'select(.event=="sweep_phase_completed" and .data.phase=="feedback-reminders" and .data.status=="completed" and .data.item_count==1 and .data.duration_s >= 0)' "$log" >/dev/null
grep -q 'should stay' "$project_root/feedback/active.md"

offset_file="$project_root/.runtime/state/test-events-offset"
mkdir -p "$(dirname "$offset_file")"
size=$(wc -c < "$log" | tr -d ' ')
printf '%s.jsonl:%s\n' "$(date -u +%Y-%m-%d)" "$size" > "$offset_file"

"$ROOT/scripts/sweep-process-events.sh" --offset-file "$offset_file"
jq -e 'select(.event=="sweep_phase_completed" and .data.phase=="process-events" and .data.status=="noop" and .data.item_count==0 and .data.duration_s >= 0)' "$log" >/dev/null

printf 'PASS: sweep phase timing\n'
