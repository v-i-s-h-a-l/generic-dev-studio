#!/usr/bin/env bash
# Verifies forge-latency-report aggregates paired event spans, explicit
# duration_s fields, missing review-gate timings, and pre/post cutover buckets.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t forge-latency.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
# shellcheck source=../../../lib-paths.sh
. "$ROOT/scripts/lib-paths.sh"
events_dir=$(resolve_events_dir_for demo)
mkdir -p "$events_dir"

cat > "$events_dir/2026-04-28.jsonl" <<'JSONL'
{"ts":"2026-04-28T10:00:00Z","agent":"chanakya","event":"task_dispatched","task":"T001","data":{}}
{"ts":"2026-04-28T10:02:00Z","agent":"achilles","event":"task_started","task":"T001","data":{}}
{"ts":"2026-04-28T10:22:00Z","agent":"achilles","event":"build_check_started","task":"T001","data":{"attempt":1}}
{"ts":"2026-04-28T10:27:00Z","agent":"achilles","event":"build_check_passed","task":"T001","data":{"duration_s":300,"attempt":1}}
{"ts":"2026-04-28T10:28:00Z","agent":"achilles","event":"review_requested","task":"T001","data":{"stage":"spec"}}
{"ts":"2026-04-28T10:31:00Z","agent":"argus","event":"review_approved","task":"T001","data":{"stage":"spec"}}
{"ts":"2026-04-28T10:32:00Z","agent":"achilles","event":"task_completed","task":"T001","data":{}}
{"ts":"2026-04-28T11:00:00Z","agent":"chanakya","event":"task_dispatched","task":"T002","data":{}}
{"ts":"2026-04-28T11:04:00Z","agent":"achilles","event":"task_started","task":"T002","data":{}}
{"ts":"2026-04-28T11:20:00Z","agent":"achilles","event":"task_completed","task":"T002","data":{}}
JSONL

cat > "$events_dir/2026-04-29.jsonl" <<'JSONL'
{"ts":"2026-04-29T10:00:00Z","agent":"studio","event":"precommit_review_passed","task":"","data":{"patch_id":"p1","verdict":"approved"}}
{"ts":"2026-04-29T10:01:00Z","agent":"studio","event":"precommit_review_failed","task":"","data":{"patch_id":"p1","status":"failed","failure_kind":"infrastructure","reason":"reviewer_command_failed","review_host":"claude-reviewer","duration_s":11}}
{"ts":"2026-04-29T12:00:00Z","agent":"chanakya","event":"task_dispatched","task":"T003","data":{}}
{"ts":"2026-04-29T12:05:00Z","agent":"achilles","event":"task_started","task":"T003","data":{}}
{"ts":"2026-04-29T12:50:00Z","agent":"achilles","event":"build_check_started","task":"T003","data":{"attempt":1}}
{"ts":"2026-04-29T13:00:00Z","agent":"achilles","event":"build_check_passed","task":"T003","data":{"duration_s":600,"attempt":1}}
{"ts":"2026-04-29T13:05:00Z","agent":"achilles","event":"review_requested","task":"T003","data":{"stage":"quality"}}
{"ts":"2026-04-29T13:17:00Z","agent":"argus","event":"review_flagged","task":"T003","data":{"stage":"quality"}}
{"ts":"2026-04-29T13:30:00Z","agent":"achilles","event":"task_completed","task":"T003","data":{}}
{"ts":"2026-04-29T13:32:00Z","agent":"studio","event":"pr_review_completed","task":"361","data":{"duration_s":135,"status":"passed","tokens":{"input":1234,"output":567,"cache_read":432,"cache_write":0}}}
{"ts":"2026-04-29T13:33:00Z","agent":"studio","event":"pr_review_completed","task":"361","data":{"duration_s":94,"status":"passed","tokens":{"input":222,"output":111,"cache_read":0,"cache_write":0}}}
{"ts":"2026-04-29T14:00:00Z","agent":"chanakya","event":"task_dispatched","task":"T004","data":{}}
{"ts":"2026-04-29T14:03:00Z","agent":"achilles","event":"task_started","task":"T004","data":{}}
{"ts":"2026-04-29T15:10:00Z","agent":"achilles","event":"task_completed","task":"T004","data":{}}
{"ts":"2026-04-29T16:00:00Z","agent":"studio","event":"pr_autopilot_completed","task":"361","data":{"duration_s":12,"status":"completed"}}
{"ts":"2026-04-29T16:01:00Z","agent":"studio","event":"pr_merge_finalize_completed","task":"361","data":{"duration_s":18,"status":"completed","cleanup_failed":false}}
{"ts":"2026-04-29T16:02:00Z","agent":"chanakya","event":"sweep_phase_completed","task":"","data":{"project":"demo","phase":"process-events","status":"completed","item_count":4,"duration_s":7}}
{"ts":"2026-04-29T16:03:00Z","agent":"chanakya","event":"sweep_phase_completed","task":"","data":{"project":"demo","phase":"feedback-reminders","status":"noop","item_count":0,"duration_s":0}}
{"ts":"2026-04-29T16:04:00Z","agent":"studio","event":"session_start_completed","task":"","data":{"host":"codex","status":"completed","duration_s":2,"budget_s":5}}
JSONL

out="$TMPROOT/out"
ACHILLES_PROJECT=demo "$ROOT/scripts/forge-latency-report.sh" \
  --since 2026-04-28 --until 2026-04-29 --cutover 2026-04-29T00:00:00Z > "$out"

grep -q 'Stage latency (ranked by total measured time)' "$out" || {
  printf 'missing stage report\n' >&2
  exit 1
}
grep -Eq '^end_to_end_task[[:space:]]+4[[:space:]]+12720' "$out" || {
  printf 'end-to-end aggregate mismatch\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^build/test[[:space:]]+2[[:space:]]+900' "$out" || {
  printf 'build/test aggregate mismatch\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^argus_review:(spec|quality)[[:space:]]+1' "$out" || {
  printf 'argus stage samples missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'pre    samples=2' "$out" || {
  printf 'pre comparison bucket missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'post   samples=2' "$out" || {
  printf 'post comparison bucket missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'pre-commit_review: 1 gap(s)' "$out" || {
  printf 'precommit telemetry gap missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^pre-commit_review_infra_failure[[:space:]]+1[[:space:]]+11' "$out" || {
  printf 'precommit infra failure aggregate missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'Pre-commit reviewer infrastructure failures' "$out" || {
  printf 'precommit infra failure section missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq 'claude-reviewer[[:space:]]+failures=1' "$out" || {
  printf 'precommit infra failure host missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq 'reviewer_command_failed[[:space:]]+failures=1' "$out" || {
  printf 'precommit infra failure reason missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'PR review token usage' "$out" || {
  printf 'pr review token summary missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^  samples=2 input_tokens=1456 output_tokens=678 cache_read_tokens=432 total_tokens=2134$' "$out" || {
  printf 'pr review token totals mismatch\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^pr_autopilot[[:space:]]+1[[:space:]]+12' "$out" || {
  printf 'pr_autopilot aggregate missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^pr_merge_finalize[[:space:]]+1[[:space:]]+18' "$out" || {
  printf 'pr_merge_finalize aggregate missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^sweep:process-events[[:space:]]+1[[:space:]]+7' "$out" || {
  printf 'sweep process-events aggregate missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^sweep:feedback-reminders[[:space:]]+1[[:space:]]+0' "$out" || {
  printf 'sweep feedback-reminders no-op aggregate missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^session_start[[:space:]]+1[[:space:]]+2' "$out" || {
  printf 'session_start aggregate missing\n' >&2
  cat "$out" >&2
  exit 1
}

printf 'PASS: forge latency report\n'
