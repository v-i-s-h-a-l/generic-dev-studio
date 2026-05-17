#!/usr/bin/env bash
# Shared typed output helpers for manager front doors.

manager_failure_json() {
  local kind="${1:?usage: manager_failure_json <kind> <mode> <stage> <reason> <message>}" \
    mode="${2:-}" \
    stage="${3:?stage required}" \
    reason="${4:?reason required}" \
    message="${5:-}"

  jq -n \
    --arg kind "$kind" \
    --arg mode "$mode" \
    --arg stage "$stage" \
    --arg reason "$reason" \
    --arg message "$message" \
    '{
      schema_version: 1,
      kind: $kind,
      status: "failed",
      failure: {
        stage: $stage,
        reason: $reason,
        message: $message
      }
    }
    | if $mode == "" then . else .mode = $mode end'
}
