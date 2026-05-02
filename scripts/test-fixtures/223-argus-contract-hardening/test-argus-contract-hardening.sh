#!/usr/bin/env bash
# Verifies the Argus dispatch timeout path and the shared base-staleness
# threshold source.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t argus-contract-223.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT="argus-contract-223"

REPO="$TMPROOT/repo"
mkdir -p "$REPO/hosts" "$REPO/.slow-reviewer" "$REPO/bin" "$TMPROOT/worktree"
ln -s "$ROOT/scripts" "$REPO/scripts"
ln -s "$ROOT/_shared" "$REPO/_shared"

cat > "$REPO/hosts/registry.yaml" <<'YAML'
slow-reviewer:
  capabilities_path: ".slow-reviewer/capabilities.yaml"
YAML

cat > "$REPO/.slow-reviewer/capabilities.yaml" <<EOF
supports_hooks: false
spawn_command: "$REPO/bin/slow-review.sh"
block_for_event_strategy: tail
tool_dialect: openai
sandbox_profile: full
secret_scope: none
EOF

cat > "$REPO/bin/slow-review.sh" <<'SH'
#!/usr/bin/env bash
sleep 5
SH
chmod +x "$REPO/bin/slow-review.sh"

# shellcheck source=../../../scripts/lib-paths.sh
. "$ROOT/scripts/lib-paths.sh"
# shellcheck source=../../../scripts/lib-ledger.sh
. "$ROOT/scripts/lib-ledger.sh"

TASK_ID="T223"
IDEM_KEY="$TASK_ID:quality:1"
REQUESTED_AT="2026-05-02T00:00:00Z"
HANDOFF_CAPTURE="$TMPROOT/handoff.json"
export STUDIO_HOST="slow-reviewer"
export TASK_SIZE="S"
export ACHILLES_REVIEW_REQUESTED_AT="$REQUESTED_AT"
export DISPATCH_REVIEW_CAPTURE_HANDOFF="$HANDOFF_CAPTURE"

emit_event_keyed argus review review_flagged "$TASK_ID" \
  '{"stage":"spec","review_file":"reviews/review_T223_spec.md","finding_count":2}' \
  --idem-key "$TASK_ID:spec:1" >/dev/null

set +e
DISPATCH_REVIEW_TIMEOUT=2 "$REPO/scripts/dispatch-review.sh" "$TASK_ID" quality \
  --idempotency-key "$IDEM_KEY" >/dev/null 2>"$TMPROOT/dispatch-stderr"
dispatch_rc=$?
set -e

if [ "$dispatch_rc" -eq 0 ]; then
  printf 'FAIL: dispatch-review unexpectedly succeeded\n' >&2
  exit 1
fi

LOG=$(resolve_event_log)
jq -e --arg req "$REQUESTED_AT" \
  'select(.event == "review_timeout" and .data.requested_at == $req and .data.timeout_s == 2 and .data.stage == "quality")' \
  "$LOG" >/dev/null
jq -e 'select(.event == "argus_gate_skipped" and .data.reason == "verdict_timeout_2s")' \
  "$LOG" >/dev/null
jq -e '.from == "chanakya" and .to == "argus" and .payload_ref.prior_findings_summary.verdict == "flagged" and .payload_ref.prior_findings_summary.finding_count == 2' \
  "$HANDOFF_CAPTURE" >/dev/null

BROKEN_REPO="$TMPROOT/broken-repo"
mkdir -p "$BROKEN_REPO"
ln -s "$ROOT/scripts" "$BROKEN_REPO/scripts"
ln -s "$ROOT/_shared" "$BROKEN_REPO/_shared"

set +e
STUDIO_HOST="slow-reviewer" "$BROKEN_REPO/scripts/dispatch-review.sh" "$TASK_ID" spec \
  --idempotency-key "$TASK_ID:spec:missing-registry" >/dev/null 2>"$TMPROOT/missing-registry-stderr"
missing_registry_rc=$?
set -e

if [ "$missing_registry_rc" -eq 0 ]; then
  printf 'FAIL: dispatch-review accepted layout without hosts/registry.yaml\n' >&2
  exit 1
fi
grep -q 'host registry missing' "$TMPROOT/missing-registry-stderr" || {
  printf 'FAIL: dispatch-review did not name missing host registry\n' >&2
  cat "$TMPROOT/missing-registry-stderr" >&2
  exit 1
}
grep -q 'sync-host-skills.sh slow-reviewer' "$TMPROOT/missing-registry-stderr" || {
  printf 'FAIL: dispatch-review missing repair command for absent registry\n' >&2
  cat "$TMPROOT/missing-registry-stderr" >&2
  exit 1
}

offset_file="$TMPROOT/events_offset.fixture"
mkdir -p "$(dirname "$offset_file")"
printf '%s.jsonl:0\n' "$(basename "$LOG" .jsonl)" > "$offset_file"
"$REPO/scripts/sweep-process-events.sh" --offset-file "$offset_file" >/dev/null
QUEUE=$(resolve_push_queue)
jq -e 'select(.kind == "review_timeout" and (.text | test("timed out"))) ' "$QUEUE" >/dev/null

BASE_DOC="$TMPROOT/base-staleness.md"
cat > "$BASE_DOC" <<'MD'
Threshold: 7
MD

set +e
DRY_RUN=1 ACHILLES_BASE_STALENESS_DOC="$BASE_DOC" "$REPO/scripts/achilles-refresh-base.sh" \
  "$TASK_ID" "$TMPROOT/worktree" main >/dev/null 2>"$TMPROOT/refresh-stderr"
refresh_rc=$?
set -e

if [ "$refresh_rc" -ne 0 ]; then
  printf 'FAIL: dry-run refresh-base exited %s\n' "$refresh_rc" >&2
  cat "$TMPROOT/refresh-stderr" >&2
  exit 1
fi

grep -q 'threshold=7' "$TMPROOT/refresh-stderr" || {
  printf 'FAIL: refresh-base did not read threshold from shared primitive\n' >&2
  cat "$TMPROOT/refresh-stderr" >&2
  exit 1
}

printf 'PASS: argus contract hardening\n'
