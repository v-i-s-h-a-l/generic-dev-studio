#!/usr/bin/env bash
# Verifies field-workflow-report aggregates stage timings, gate quality,
# review coverage, token usage, telemetry gaps, and improvement candidates.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t field-workflow.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
# shellcheck source=../../../lib-paths.sh
. "$ROOT/scripts/lib-paths.sh"

project_root=$(resolve_project_root_for demo)
events_dir="$project_root/events"
briefs_dir="$project_root/plans/briefs"
mkdir -p "$events_dir" "$briefs_dir"

cat > "$briefs_dir/brief-001.yaml" <<'YAML'
id: brief-001
task_id: task-001
legacy_task_id: "T001"
type: impl
size: s
state: dispatched
acceptance:
  - "Report prints gate pass rates."
summary: |
  Add Field workflow telemetry.
recommended_models:
  best_result:
    model_id: claude-sonnet-default
YAML

cat > "$briefs_dir/brief-002.yaml" <<'YAML'
id: brief-002
task_id: task-002
legacy_task_id: "T002"
type: impl
size: s
state: dispatched
acceptance: []
summary: null
recommended_models:
  best_result:
    model_id: claude-haiku-default
YAML

cat > "$events_dir/2026-04-29.jsonl" <<'JSONL'
{"ts":"2026-04-29T10:00:00Z","agent":"chanakya","event":"brief_started","task":"T001","data":{"size":"s"}}
{"ts":"2026-04-29T10:05:00Z","agent":"chanakya","event":"brief_state_changed","task":"T001","data":{"to":"ready","size":"s"}}
{"ts":"2026-04-29T10:08:00Z","agent":"chanakya","event":"brief_dispatched","task":"T001","data":{"brief_uuid":"brief-001","task_id":"task-001","size":"s"}}
{"ts":"2026-04-29T10:10:00Z","agent":"achilles","event":"task_started","task":"T001","data":{"size":"s"}}
{"ts":"2026-04-29T10:20:00Z","agent":"achilles","event":"build_check_started","task":"T001","data":{"mode":"lsp-only","attempt":1}}
{"ts":"2026-04-29T10:21:00Z","agent":"achilles","event":"build_check_passed","task":"T001","data":{"mode":"lsp-only","attempt":1,"duration_s":60,"warnings":1,"errors":0}}
{"ts":"2026-04-29T10:22:00Z","agent":"achilles","event":"review_requested","task":"T001","data":{"stage":"quality"}}
{"ts":"2026-04-29T10:25:00Z","agent":"argus","event":"review_approved","task":"T001","data":{"stage":"quality"}}
{"ts":"2026-04-29T10:27:00Z","agent":"achilles","event":"task_merged","task":"T001","data":{"merge_sha":"abc"}}
{"ts":"2026-04-29T10:28:00Z","agent":"achilles","event":"agent_session_completed","task":"T001","data":{"mode":"task","duration_s":1680,"tokens":{"input":65000,"output":10000,"cache_read":5000},"model_selected":"claude-sonnet-default","host":"codex"}}
{"ts":"2026-04-29T11:00:00Z","agent":"chanakya","event":"brief_dispatched","task":"T002","data":{"brief_uuid":"brief-002","task_id":"task-002","size":"s"}}
{"ts":"2026-04-29T11:01:00Z","agent":"achilles","event":"task_started","task":"T002","data":{"size":"s"}}
{"ts":"2026-04-29T11:02:00Z","agent":"achilles","event":"build_queue_position","task":"T002","data":{"mode":"full-green","node":"mini-1","position":3,"depth":4,"attempt":1}}
{"ts":"2026-04-29T11:03:00Z","agent":"achilles","event":"build_check_started","task":"T002","data":{"mode":"full-green","attempt":1,"studio.dispatch.node":"mini-1","studio.dispatch.reason":"remote_unreachable"}}
{"ts":"2026-04-29T11:08:00Z","agent":"achilles","event":"build_check_failed","task":"T002","data":{"mode":"full-green","attempt":1,"duration_s":300,"reason":"remote_shell_path_failed","warnings":2,"errors":1,"studio.dispatch.node":"mini-1","studio.dispatch.reason":"remote_unreachable"}}
{"ts":"2026-04-29T11:10:00Z","agent":"achilles","event":"build_check_started","task":"T002","data":{"mode":"full-green","attempt":2,"studio.dispatch.node":"mini-1"}}
{"ts":"2026-04-29T11:13:00Z","agent":"achilles","event":"build_check_passed","task":"T002","data":{"mode":"full-green","attempt":2,"duration_s":180,"warnings":0,"errors":0,"studio.dispatch.node":"mini-1"}}
{"ts":"2026-04-29T11:14:00Z","agent":"argus","event":"argus_gate_skipped","task":"T002","data":{"stage":"quality","reason":"verdict_timeout_900s","host":"mini-1"}}
{"ts":"2026-04-29T11:15:00Z","agent":"chanakya","event":"task_redispatched","task":"T002","data":{"reason":"user_retry"}}
{"ts":"2026-04-29T11:16:00Z","agent":"achilles","event":"agent_session_completed","task":"T002","data":{"mode":"task","duration_s":960,"model_selected":"claude-sonnet-default","host":"codex"}}
{"ts":"2026-04-29T11:17:00Z","agent":"achilles","event":"test_run_started","task":"T002","data":{"node":"mini-1","attempt":1}}
{"ts":"2026-04-29T11:20:00Z","agent":"achilles","event":"test_run_failed","task":"T002","data":{"node":"mini-1","attempt":1,"duration_s":180,"reason":"test_failure","errors":1}}
JSONL

out="$TMPROOT/out"
ACHILLES_PROJECT=demo "$ROOT/scripts/field-workflow-report.sh" \
  --project demo --since 2026-04-29 --until 2026-04-29 > "$out"

grep -q 'Stage timing (ranked by total measured time)' "$out" || {
  printf 'missing stage timing table\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^brief_authoring[[:space:]]+1[[:space:]]+480' "$out" || {
  printf 'brief authoring duration mismatch\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^build_gate:full-green[[:space:]]+2[[:space:]]+480' "$out" || {
  printf 'full-green build duration mismatch\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^full-green[[:space:]]+mini-1[[:space:]]+2[[:space:]]+1[[:space:]]+1[[:space:]]+50.0%' "$out" || {
  printf 'full-green pass-rate row missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'remote_shell_path' "$out" || {
  printf 'failure class missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^quality[[:space:]]+1[[:space:]]+1[[:space:]]+0[[:space:]]+0[[:space:]]+1' "$out" || {
  printf 'review coverage row missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -Eq '^achilles[[:space:]]+task[[:space:]]+claude-sonnet-default[[:space:]]+codex[[:space:]]+s[[:space:]]+1[[:space:]]+75000' "$out" || {
  printf 'token usage row missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'token_usage .*missing_token_fields=1' "$out" || {
  printf 'missing token telemetry gap not reported\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'High token cost on small tasks' "$out" || {
  printf 'small-task token improvement missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'Argus coverage is degraded' "$out" || {
  printf 'Argus improvement missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'Remote dispatch fallback occurred' "$out" || {
  printf 'remote fallback improvement missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'Privacy note' "$out" || {
  printf 'privacy note missing\n' >&2
  cat "$out" >&2
  exit 1
}

printf 'PASS: field workflow report\n'
