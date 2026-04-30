#!/usr/bin/env bash
# Best-effort phase timing for inbox-sweep scripts. Telemetry failure must not
# affect sweep correctness.

SWEEP_TIMING_STARTED_AT=""

sweep_timing_start() {
  SWEEP_TIMING_STARTED_AT=$(date -u +%s)
}

sweep_timing_emit() {
  local phase="${1:?sweep_timing_emit <phase> <status> <item-count>}"
  local status="${2:?}"
  local item_count="${3:-0}"
  local duration_s now project

  case "$item_count" in ''|*[!0-9]*) item_count=0 ;; esac
  now=$(date -u +%s)
  if [ -n "$SWEEP_TIMING_STARTED_AT" ]; then
    duration_s=$(( now - SWEEP_TIMING_STARTED_AT ))
  else
    duration_s=0
  fi
  [ "$duration_s" -ge 0 ] && [ "$duration_s" -le 86400 ] || return 0

  project="${PROJECT:-}"
  if [ -z "$project" ] && command -v resolve_project >/dev/null 2>&1; then
    project=$(resolve_project 2>/dev/null || echo "")
  fi

  local data
  data=$(printf '{"project":"%s","phase":"%s","status":"%s","item_count":%s,"duration_s":%s}' \
    "$(_json_escape "$project")" \
    "$(_json_escape "$phase")" \
    "$(_json_escape "$status")" \
    "$item_count" \
    "$duration_s")
  emit_event_keyed chanakya inbox-sweep sweep_phase_completed "" "$data" \
    --idem-key "sweep-phase:${project}:${phase}:${SWEEP_TIMING_STARTED_AT}:${status}:${item_count}" \
    >/dev/null 2>&1 || true
}
