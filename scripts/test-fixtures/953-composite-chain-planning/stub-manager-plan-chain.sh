#!/usr/bin/env bash

set -euo pipefail

[ -n "${STUDIO_MANAGER_PLAN_CHAIN_RUN_ID:-}" ] || {
  printf 'stub-manager-plan-chain: STUDIO_MANAGER_PLAN_CHAIN_RUN_ID required\n' >&2
  exit 2
}

if [ -n "${STUB_PLAN_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$STUB_PLAN_LOG"
fi

include_comments=0
issue_source=0
body_only=0
project="generic-dev-studio"
repo="v-i-s-h-a-l/generic-dev-studio"
prev=""
for arg in "$@"; do
  case "$arg" in
    --issue)
      issue_source=1
      ;;
    --include-comments)
      include_comments=1
      ;;
    --body-only)
      body_only=1
      ;;
    *)
      case "$prev" in
        --project) project="$arg" ;;
        --repo) repo="$arg" ;;
      esac
      ;;
  esac
  prev="$arg"
done

artifact_root="$HOME/.dev-studio/$project/plan-chains/$STUDIO_MANAGER_PLAN_CHAIN_RUN_ID"
mkdir -p "$artifact_root"

if [ "$issue_source" -eq 1 ] && [ "$body_only" -eq 0 ]; then
  include_comments=1
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
  --arg repo "$repo" \
  --argjson include_comments "$include_comments" \
  --arg review "$review" \
  --arg work_chain "$work_chain" \
  '{
    schema_version: 1,
    kind: "manager-plan-chain-result",
    status: $status,
    artifact_root: $artifact_root,
    planner_artifact: $planner,
    source_context: {
      comments_included: ($include_comments == 1),
      mode: (if $include_comments == 1 then "issue-context-packet" else "body-only" end),
      packet_path: (if $include_comments == 1 then ($artifact_root + "/issue-context-packet/packet.md") else null end),
      comment_sidecar_path: (if $include_comments == 1 then ($artifact_root + "/issue-context-packet/packet.json") else null end),
      body_only_explicit: ($include_comments != 1)
    },
    review_artifact: $review,
    work_chain: (if $status == "ready" then $work_chain else null end),
    created_issues: [
      {
        node_id: "T001",
        number: 9001,
        url: ("https://github.com/" + $repo + "/issues/9001")
      }
    ],
    parent_issue: {
      number: 123,
      url: ("https://github.com/" + $repo + "/issues/123")
    },
    blocked_decisions: (if $status == "ready" then [] else ["stubbed planner block"] end)
  }' > "$artifact_root/result.json"

exit "$exit_code"
