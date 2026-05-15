#!/usr/bin/env bash

set -euo pipefail

[ -n "${STUDIO_MANAGER_PLAN_CHAIN_RUN_ID:-}" ] || {
  printf 'stub-manager-plan-chain: STUDIO_MANAGER_PLAN_CHAIN_RUN_ID required\n' >&2
  exit 2
}

artifact_root="$HOME/.dev-studio/generic-dev-studio/plan-chains/$STUDIO_MANAGER_PLAN_CHAIN_RUN_ID"
mkdir -p "$artifact_root"

if [ -n "${STUB_PLAN_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$STUB_PLAN_LOG"
fi

status="${STUB_PLAN_STATUS:-ready}"
exit_code="${STUB_PLAN_EXIT_CODE:-0}"
planner="$artifact_root/planner-output.json"
review="$artifact_root/plan-review.md"
work_chain="$artifact_root/work-chain.yaml"

printf '{"kind":"planner-output","status":"ready"}\n' > "$planner"
printf '# Plan Review\n\nclean\n' > "$review"
printf 'schema_version: 1\nchains: []\n' > "$work_chain"

jq -n \
  --arg status "$status" \
  --arg artifact_root "$artifact_root" \
  --arg planner "$planner" \
  --arg review "$review" \
  --arg work_chain "$work_chain" \
  '{
    schema_version: 1,
    kind: "manager-plan-chain-result",
    status: $status,
    artifact_root: $artifact_root,
    planner_artifact: $planner,
    review_artifact: $review,
    work_chain: (if $status == "ready" then $work_chain else null end),
    created_issues: [
      {
        node_id: "T001",
        number: 9001,
        url: "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/9001"
      }
    ],
    parent_issue: {
      number: 123,
      url: "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/123"
    },
    blocked_decisions: (if $status == "ready" then [] else ["stubbed planner block"] end)
  }' > "$artifact_root/result.json"

exit "$exit_code"
