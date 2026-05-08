#!/usr/bin/env bash
# Verifies issue identity and checkpoint drift details survive state, halt, report, and digest surfaces.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
DIGEST="$ROOT/scripts/studio-chain-telemetry-digest.sh"
TMPROOT=$(mktemp -d -t chain-state-diagnostics-769.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"

helper_block="$TMPROOT/checkpoint-helpers.sh"
awk '
  /^sanitize_checkpoint_component\(\)/ { capture=1 }
  /^halt_class_for_reason\(\)/ { capture=0 }
  capture { print }
' "$RUNNER" > "$helper_block"

RUN_ID="019e0969-7690-7000-8000-000000000001"
CHAIN_RUN_ID="019e0969-7690-7000-8000-000000000002"
ISSUE_RUN_ID="019e0969-7690-7000-8000-000000000003"
CHAIN_RUN_ROOT="$TMPROOT/chain-runs/run-rich"
mkdir -p "$CHAIN_RUN_ROOT"

iso_ts_now() { printf '2026-05-09T00:00:00Z\n'; }

# shellcheck source=/dev/null
. "$helper_block"

read_set="$CHAIN_RUN_ROOT/checkpoint-load-$CHAIN_RUN_ID.reads"
printf 'manifest.json\ncontext.md\nstate.json\n' > "$read_set"
drift_artifact=$(write_checkpoint_drift_artifact \
  "$CHAIN_RUN_ID" \
  "ckpt-769" \
  "$CHAIN_RUN_ROOT/checkpoints/ckpt-769" \
  "feature/chain-state-diagnostics" \
  "expected769" \
  "observed769" \
  "confirmed" \
  "$read_set" \
  "resume_drift_confirmed" \
  "checkpoint resume drift confirmed for ckpt-769")

jq -e --arg read_set "$read_set" '
  .kind == "chain-checkpoint-drift"
  and .checkpoint_id == "ckpt-769"
  and .expected_commit == "expected769"
  and .observed_commit == "observed769"
  and .read_set_artifact == $read_set
  and (.read_set == ["manifest.json", "context.md", "state.json"])
' "$drift_artifact" >/dev/null || {
  cat "$drift_artifact" >&2
  fail "checkpoint drift artifact did not carry expected diagnostics"
}

RUNS="$TMPROOT/chain-runs"
RICH_RUN="$RUNS/run-rich"
OLD_RUN="$RUNS/run-old"
SUMMARY_ROOT="$RICH_RUN/worker-summaries"
HALT_ROOT="$RICH_RUN/halt-records"
EVENTS_JSONL="$RICH_RUN/events.jsonl"
RUN_STATE_JSON="$RICH_RUN/state.json"
RUN_REPORT="$RICH_RUN/report.md"
mkdir -p "$SUMMARY_ROOT" "$HALT_ROOT" "$OLD_RUN"
: > "$EVENTS_JSONL"

cat > "$RUN_STATE_JSON" <<JSON
{
  "schema_version": 1,
  "run_id": "$RUN_ID",
  "manifest": "chains/diagnostics.yaml",
  "status": "failed",
  "started_at": "2026-05-09T00:00:00Z",
  "updated_at": "2026-05-09T00:00:10Z",
  "chains": [
    {
      "name": "diagnostics",
      "chain_run_id": "$CHAIN_RUN_ID",
      "status": "failed",
      "issues": [
        {
          "number": 76901,
          "issue_number": 76901,
          "title": "Carry identity through state",
          "issue_title": "Carry identity through state",
          "issue_run_id": "$ISSUE_RUN_ID",
          "status": "failed",
          "dependencies": [76900],
          "commit_after": "observed769",
          "summary": "$SUMMARY_ROOT/issue-76901.json"
        }
      ]
    }
  ],
  "halt_records": [
    {
      "path": "$HALT_ROOT/checkpoint-drift.json",
      "reason_id": "checkpoint_drift_detected",
      "halt_class": "recoverable",
      "status": "paused",
      "next_command": "scripts/studio-chain-runner.sh --resume $RUN_ID --yes",
      "next_safe_action": "Inspect the checkpoint drift artifact and read-set before resuming.",
      "issue_context": {
        "chain": "diagnostics",
        "chain_run_id": "$CHAIN_RUN_ID",
        "issue_run_id": "$ISSUE_RUN_ID",
        "issue_number": 76901,
        "title": "Carry identity through state",
        "status": "failed",
        "dependencies": [76900],
        "commit_after": "observed769"
      },
      "details": {
        "checkpoint_id": "ckpt-769",
        "expected_commit": "expected769",
        "observed_commit": "observed769",
        "read_set_artifact": "$read_set",
        "drift_artifact": "$drift_artifact"
      }
    }
  ]
}
JSON

cat > "$SUMMARY_ROOT/issue-76901.json" <<JSON
{
  "schema_version": 1,
  "kind": "completion",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "$ISSUE_RUN_ID",
  "chain": "diagnostics",
  "issue_number": 76901,
  "issue_title": "Carry identity through state",
  "host": "codex",
  "exit_code": 1,
  "duration_s": 5,
  "commit_after": "observed769",
  "files_changed": 1,
  "additions": 1,
  "deletions": 0,
  "generated_file_count": 0,
  "tokens": null,
  "tests": [],
  "lints": [],
  "builds": [],
  "telemetry_gaps": ["tokens"]
}
JSON

cat > "$HALT_ROOT/checkpoint-drift.json" <<JSON
{
  "schema_version": 1,
  "kind": "chain-halt-record",
  "created_at": "2026-05-09T00:00:11Z",
  "run_id": "$RUN_ID",
  "chain_run_id": "$CHAIN_RUN_ID",
  "issue_run_id": "$ISSUE_RUN_ID",
  "chain": "diagnostics",
  "issue_number": 76901,
  "status": "paused",
  "reason_id": "checkpoint_drift_detected",
  "halt_class": "recoverable",
  "writer": "parent-runner",
  "summary": "checkpoint resume drift confirmed for ckpt-769",
  "issue_context": {
    "chain": "diagnostics",
    "chain_run_id": "$CHAIN_RUN_ID",
    "issue_run_id": "$ISSUE_RUN_ID",
    "issue_number": 76901,
    "title": "Carry identity through state",
    "status": "failed",
    "dependencies": [76900],
    "commit_after": "observed769"
  },
  "details": {
    "checkpoint_id": "ckpt-769",
    "expected_commit": "expected769",
    "observed_commit": "observed769",
    "read_set_artifact": "$read_set",
    "drift_artifact": "$drift_artifact"
  },
  "resumable_state": {
    "run_state": "$RUN_STATE_JSON",
    "issue_context": {"issue_run_id": "$ISSUE_RUN_ID"},
    "next_safe_action": "Inspect the checkpoint drift artifact and read-set before resuming."
  },
  "next_command": "scripts/studio-chain-runner.sh --resume $RUN_ID --yes",
  "next_safe_action": "Inspect the checkpoint drift artifact and read-set before resuming.",
  "affected_artifacts": ["$RUN_STATE_JSON", "$RUN_REPORT", "$drift_artifact", "$read_set"],
  "rollback_path": "Realign the chain worktree or checkpoint, then resume.",
  "true_hard_stop": false,
  "human_action_required": false,
  "privacy": {"classification": "private-runtime"}
}
JSON

"$ROOT/scripts/validate-contract.sh" chain-halt-record "$HALT_ROOT/checkpoint-drift.json" >/dev/null

cat > "$OLD_RUN/state.json" <<'JSON'
{
  "schema_version": 1,
  "run_id": "run-old",
  "manifest": "chains/old.yaml",
  "status": "completed",
  "started_at": "2026-05-09T00:01:00Z",
  "updated_at": "2026-05-09T00:01:10Z",
  "chains": [
    {
      "name": "old-shape",
      "issues": [
        {
          "number": 76902,
          "title": "Old readable state row",
          "status": "completed"
        }
      ]
    }
  ]
}
JSON

digest_json="$TMPROOT/digest.json"
"$DIGEST" --chain-runs-root "$RUNS" --since 2026-05-09 --until 2026-05-09 --format json > "$digest_json"
jq -e --arg issue_run_id "$ISSUE_RUN_ID" '
  (.issues[] | select(.issue_number == 76901)
    | .issue_run_id == $issue_run_id
      and .issue_title == "Carry identity through state"
      and .status == "failed"
      and .dependencies == [76900]
      and .commit_after == "observed769")
  and (.issues[] | select(.issue_number == 76902)
    | .issue_run_id == null
      and .issue_title == "Old readable state row"
      and .commit_after == null)
' "$digest_json" >/dev/null || {
  cat "$digest_json" >&2
  fail "digest issue rows did not preserve rich and old state shapes"
}

digest_md="$TMPROOT/digest.md"
"$DIGEST" --chain-run-root "$RICH_RUN" --since 2026-05-09 --until 2026-05-09 --format markdown > "$digest_md"
for needle in \
  "Carry identity through state" \
  "$ISSUE_RUN_ID" \
  "#76900" \
  "observed769"
do
  grep -Fq "$needle" "$digest_md" || {
    cat "$digest_md" >&2
    fail "missing digest markdown issue context: $needle"
  }
done

generate_report_block="$TMPROOT/generate-report.sh"
awk '/^generate_run_report\(\)/,/^finish_run\(\)/ { if ($0 !~ /^finish_run\(\)/) print }' \
  "$RUNNER" > "$generate_report_block"

SCRIPT_DIR="$ROOT/scripts"
MANIFEST="chains/diagnostics.yaml"
RUN_STATUS="failed"
RUN_FAILURE_REASON="checkpoint drift"
RUN_STARTED_AT=100
RUN_STARTED_TS="2026-05-09T00:00:00Z"
FINAL_PR_URL=""

now_epoch() { printf '120\n'; }
duration_since() { printf '%s\n' "$(( ${2:-120} - $1 ))"; }

# shellcheck source=/dev/null
. "$generate_report_block"
generate_run_report failed "checkpoint drift"

for needle in \
  "## State Issue Rows" \
  "$ISSUE_RUN_ID" \
  "Carry identity through state" \
  "#76900" \
  "observed769" \
  "Inspect the checkpoint drift artifact and read-set before resuming."
do
  grep -Fq "$needle" "$RUN_REPORT" || {
    cat "$RUN_REPORT" >&2
    fail "missing report diagnostic: $needle"
  }
done

printf 'PASS: chain state, halt, report, and drift diagnostics\n'
