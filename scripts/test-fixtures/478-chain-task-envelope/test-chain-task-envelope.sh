#!/usr/bin/env bash
# Verifies autonomous chain start/completion envelopes validate and runner wiring exists.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-task-envelope.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

cat > "$TMPROOT/start.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "start",
  "created_at": "2026-05-03T00:00:00Z",
  "run_id": "019dec7f-271e-7574-a4cc-ab2ec7edfd7c",
  "chain_run_id": "019dec7f-2798-786f-a2b5-1bee59583334",
  "issue_run_id": "019dec7f-2aec-7724-ac41-304d93f45f09",
  "source_issue": {
    "number": 478,
    "title": "Autonomous chains: standard task handoff envelopes",
    "body": "Define compact handoff envelopes.",
    "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/478",
    "state": "OPEN"
  },
  "ownership": {
    "chain": "autonomous-continuation-loop-478",
    "branch": "feature/autonomous-continuation-loop-478",
    "issue_branch": "feature/autonomous-continuation-loop-478-issue-478",
    "worktree": "/tmp/studio-chain-runner/autonomous-continuation-loop-478-issue-478",
    "host": "codex"
  },
  "expected_summary_artifact": "/tmp/studio-chain-runner/autonomous-continuation-loop-478-issue-478/.studio/chain-worker-summary.json",
  "required_checks": ["Commit the scoped issue change before exit."],
  "allowed_assumptions": ["The issue body is the authoritative scoped brief."],
  "stop_conditions": ["Exit non-zero after writing blocked_reason when blocked."],
  "privacy": {
    "classification": "private-runtime",
    "rules": ["Do not commit .studio artifacts."]
  }
}
JSON

cat > "$TMPROOT/completion.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "completion",
  "created_at": "2026-05-03T00:00:20Z",
  "status": "completed",
  "run_id": "019dec7f-271e-7574-a4cc-ab2ec7edfd7c",
  "chain_run_id": "019dec7f-2798-786f-a2b5-1bee59583334",
  "issue_run_id": "019dec7f-2aec-7724-ac41-304d93f45f09",
  "chain": "autonomous-continuation-loop-478",
  "issue_number": 478,
  "issue_title": "Autonomous chains: standard task handoff envelopes",
  "host": "codex",
  "model": null,
  "duration_s": 20,
  "exit_code": 0,
  "commit_before": "b779d98c97a976e9ba14e9ce5e8f4488f321c661",
  "commit_after": "b779d98c97a976e9ba14e9ce5e8f4488f321c662",
  "files_changed": 3,
  "additions": 120,
  "deletions": 4,
  "generated_file_count": 0,
  "changed_artifacts": ["_shared/contracts/chain-task-envelope.schema.json"],
  "commit_or_pr_references": {
    "commit_before": "b779d98c97a976e9ba14e9ce5e8f4488f321c661",
    "commit_after": "b779d98c97a976e9ba14e9ce5e8f4488f321c662",
    "pr_url": null,
    "pr_number": null
  },
  "tests": [{"command": "fixture", "outcome": "pass"}],
  "lints": [],
  "builds": [],
  "tokens": null,
  "functionality_delivered": ["Workers can start from a bounded envelope."],
  "refactoring_needed_now": [
    {
      "kind": "localized_cleanup",
      "reason": "Needed to keep this summary normalization maintainable.",
      "affected_area": "completion summary",
      "risk": "low",
      "implemented_change": "Kept the action summary fields explicit."
    }
  ],
  "refactoring_follow_ups": [
    {
      "kind": "awkward_boundary",
      "reason": "Runner reports and chain envelopes share summary vocabulary.",
      "affected_area": "chain reporting contracts",
      "risk": "medium",
      "suggested_timing": "After the current chain completes."
    }
  ],
  "decisions_made": ["Reuse chain-worker-summary.json as the completion envelope."],
  "assumptions_escrowed": [],
  "next_recommended_action": "Continue the chain with the normalized completion summary.",
  "telemetry_gaps": ["model", "tokens"]
}
JSON

"$ROOT/scripts/validate-contract.sh" chain-task-envelope "$TMPROOT/start.json"
"$ROOT/scripts/validate-contract.sh" chain-task-envelope "$TMPROOT/completion.json"

grep -q 'write_chain_task_start_envelope' "$ROOT/scripts/studio-chain-runner.sh" || {
  printf 'runner does not write start envelopes\n' >&2
  exit 1
}
grep -q 'kind: (.kind // "completion")' "$ROOT/scripts/studio-chain-runner.sh" || {
  printf 'runner does not normalize completion kind\n' >&2
  exit 1
}
grep -q 'created_at: (.created_at // $created_at)' "$ROOT/scripts/studio-chain-runner.sh" || {
  printf 'runner does not normalize completion created_at\n' >&2
  exit 1
}

printf 'PASS: chain-task-envelope contract\n'
