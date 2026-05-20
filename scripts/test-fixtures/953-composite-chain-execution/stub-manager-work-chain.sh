#!/usr/bin/env bash

set -euo pipefail

manifest="${1:?manifest required}"
shift

if [ -n "${STUB_WORK_LOG:-}" ]; then
  printf '%s %s\n' "$manifest" "$*" >> "$STUB_WORK_LOG"
fi

if [ -n "${STUB_WORK_RUN_ID:-}" ]; then
  run_id="$STUB_WORK_RUN_ID"
elif [ -n "${STUB_WORK_RUN_ID_PREFIX:-}" ] && [ -n "${STUB_WORK_LOG:-}" ]; then
  call_count=$(wc -l < "$STUB_WORK_LOG" | tr -d ' ')
  run_id="${STUB_WORK_RUN_ID_PREFIX}${call_count}"
else
  run_id="019e2c8a-9570-7000-8000-000000000101"
fi
status="${STUB_WORK_STATUS:-completed}"
exit_code="${STUB_WORK_EXIT_CODE:-0}"
project="${STUDIO_COMPOSITE_PLAN_CHAIN_PROJECT:-generic-dev-studio}"
root="$HOME/.dev-studio/$project/chain-runs/$run_id"
summary="$root/worker-summaries/summary-9001.json"
report="$root/report.md"

mkdir -p "$(dirname "$summary")"
printf '{"issue_number":9001,"status":"completed","summary":"stub child completed"}\n' > "$summary"
printf '# Stub Work-Chain Report\n' > "$report"

jq -n \
  --arg run_id "$run_id" \
  --arg manifest "$manifest" \
  --arg status "$status" \
  --arg report "$report" \
  --arg summary "$summary" \
  '{
    schema_version: 1,
    run_id: $run_id,
    manifest: $manifest,
    status: $status,
    started_at: "2026-05-15T17:00:00Z",
    updated_at: "2026-05-15T17:01:00Z",
    report: $report,
    chains: [
      {
        chain_run_id: "019e2c8a-9570-7000-8000-000000000201",
        name: "first-child",
        status: $status,
        pr_url: (if $status == "completed" then "https://github.com/v-i-s-h-a-l/generic-dev-studio/pull/9901" else null end),
        issues: [
          {
            issue_run_id: "019e2c8a-9570-7000-8000-000000000301",
            number: 9001,
            status: $status,
            url: "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/9001",
            summary: $summary
          }
        ]
      }
    ]
  }' > "$root/state.json"

printf '## Work-Chain Finish Summary\n\n'
# shellcheck disable=SC2016
printf -- '- Status: `%s`\n' "$status"
# shellcheck disable=SC2016
printf -- '- Run UUID: `%s`\n' "$run_id"
# shellcheck disable=SC2016
printf -- '- Private report: `%s`\n' "$report"

exit "$exit_code"
