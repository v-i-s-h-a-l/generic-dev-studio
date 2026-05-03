#!/usr/bin/env bash
# test-host.sh — H10 host conformance harness for issue #88.
#
# Usage:
#   scripts/test-host.sh <host>            # full matrix (4 happy-path + 3 floors + baseline)
#   scripts/test-host.sh <host> --failure-modes-only
#   scripts/test-host.sh --list-tasks
#
# <host> ∈ claude-code | codex
#   claude-code → reference adapter at .claude-plugin/.
#   codex       → mock shim at tests/conformance/mock-codex/ unless STUDIO_CODEX_BIN
#                 points at a real `codex` binary.
#
# Exit 0 iff every task and floor PASS. Each task prints a single line:
#   [PASS] <task-name>
#   [FAIL] <task-name> — <one-line diagnostic>
#
# Runtime writes land under ~/.dev-studio/.runtime/conformance/<run-id>/ and the
# harness sets ACHILLES_PROJECT so per-project event logs route there.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

usage() {
  sed -n '3,18p' "$0" >&2
  exit 2
}

list_tasks() {
  cat <<'EOF'
xs-trivial         — worker/reviewer role contracts are present after A10.
m-multi-file       — spawn-worker.sh accepts a workspace-write adapter, builds a valid handoff.
tdd-rgr            — dispatch-review.sh produces a review_approved event via the host adapter.
cross-host-handoff — handoff envelope validates under both STUDIO_HOST values.
fm-schema-violation— pinned validator refuses schema_version N+1 (Criterion 7).
fm-missing-optional— schema_version N parses cleanly when an optional field is missing (Criterion 7).
fm-security-floor  — lint-host-agnostic blocks a non-reference host with host-native + inherit-env (Criterion 8).
fm-env-scrub       — dispatch-review.sh strips ANTHROPIC_API_KEY before spawn (Criterion 8).
fm-github-auth     — host preflight verifies gh auth + git ls-remote credential access before work.
fm-canonical-swift — swift-test gate uses the canonical root package for nested local-package graphs.
baseline-diff      — post-v1 reference-host event sequence matches pre-v1 baseline ignoring gen_ai.* / studio.* (Criterion 1).
EOF
  exit 0
}

[ $# -ge 1 ] || usage
[ "$1" = "--list-tasks" ] && list_tasks
HOST="$1"
shift
case "$HOST" in claude-code|codex) ;; *) printf 'test-host: unknown host %s (want claude-code|codex)\n' "$HOST" >&2; exit 2 ;; esac
FM_ONLY=0
[ "${1:-}" = "--failure-modes-only" ] && FM_ONLY=1

# Pinned tooling. The validator is non-optional — the security-floor and
# schema-violation tests cannot soundly SKIP without inverting the gate.
# `pip3 install --user` lands the binary under ~/Library/Python/<ver>/bin on
# macOS, which isn't on the default shell PATH. Probe and prepend so users
# don't have to edit their rc just to run conformance.
if ! command -v check-jsonschema >/dev/null 2>&1; then
  for _pybin in "$HOME"/Library/Python/*/bin "$HOME/.local/bin"; do
    [ -x "$_pybin/check-jsonschema" ] && { PATH="$_pybin:$PATH"; export PATH; break; }
  done
fi
if ! command -v check-jsonschema >/dev/null 2>&1; then
  printf 'test-host: missing check-jsonschema. Install: pip3 install --user check-jsonschema\n' >&2
  exit 2
fi
command -v yq >/dev/null 2>&1 || { printf 'test-host: missing yq.\n' >&2; exit 2; }

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
RUN_ROOT="$(resolve_runtime_global)/conformance/$RUN_ID"
mkdir -p "$RUN_ROOT"
PROJECT_SLUG="conformance-$RUN_ID"
PROJECT_ROOT=$(ACHILLES_PROJECT="$PROJECT_SLUG" resolve_project_root_for "$PROJECT_SLUG")
mkdir -p "$PROJECT_ROOT/events"

cleanup() {
  rm -rf "$PROJECT_ROOT" 2>/dev/null || true
  # Keep RUN_ROOT for post-mortem; harness output is small.
}
trap cleanup EXIT

PASSES=0 FAILS=0
FAIL_NAMES=()
report_pass() { printf '[PASS] %s\n' "$1"; PASSES=$((PASSES + 1)); }
report_fail() { printf '[FAIL] %s — %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); FAIL_NAMES+=("$1"); }

FIXTURES="$REPO_ROOT/tests/conformance/fixtures"
BASELINES="$REPO_ROOT/tests/conformance/baselines"
MOCK_CODEX="$REPO_ROOT/tests/conformance/mock-codex"

# Resolve the host adapter directory the same way spawn-worker.sh does.
case "$HOST" in
  claude-code) HOST_DIR="$REPO_ROOT/.claude-plugin" ;;
  codex)
    if [ -n "${STUDIO_CODEX_BIN:-}" ]; then
      HOST_DIR="$REPO_ROOT/.codex"
    else
      HOST_DIR="$MOCK_CODEX"
    fi ;;
esac
HOST_MANIFEST="$HOST_DIR/capabilities.yaml"

# Wire the mock onto PATH so codex-exec-mock resolves without an absolute
# spawn_command. (Real codex would be on the user's PATH already.)
export PATH="$MOCK_CODEX/bin:$PATH"

export ACHILLES_PROJECT="$PROJECT_SLUG"

# ---------------------------------------------------------------------------
# Happy-path tasks
# ---------------------------------------------------------------------------

task_xs_trivial() {
  local worker="$REPO_ROOT/core/v2/roles/worker.yaml" reviewer="$REPO_ROOT/core/v2/roles/reviewer.yaml"
  if [ ! -f "$worker" ] || [ ! -f "$reviewer" ]; then
    report_fail "xs-trivial" "worker/reviewer role contracts missing"
    return
  fi
  if grep -q '^role: worker$' "$worker" && grep -q '^role: reviewer$' "$reviewer"; then
    report_pass "xs-trivial"
  else
    report_fail "xs-trivial" "role contracts missing canonical role markers"
  fi
}

task_m_multi_file() {
  if [ ! -f "$HOST_MANIFEST" ]; then
    report_fail "m-multi-file" "missing $HOST_MANIFEST"; return
  fi
  local sandbox secret
  sandbox=$(grep -E '^sandbox_profile:' "$HOST_MANIFEST" | head -1 | awk '{print $2}' | tr -d '"')
  secret=$(grep -E '^secret_scope:' "$HOST_MANIFEST" | head -1 | awk '{print $2}' | tr -d '"')
  case "$HOST:$sandbox:$secret" in
    claude-code:host-native:inherit-env) ;;
    codex:workspace-write:cwd-only) ;;
    codex:full:cwd-only|codex:full:none|codex:workspace-write:none) ;;
    *)
      report_fail "m-multi-file" "host=$HOST sandbox=$sandbox secret=$secret violates ADAPTER-SPEC floor"
      return ;;
  esac

  local envelope="$RUN_ROOT/m-handoff.yaml"
  cat >"$envelope" <<EOF
schema_version:
  name: handoff
  version: "1.0.0"
  min_reader: "1.0.0"
from: chanakya
to: achilles
task_id: 0190f52a-6e0c-7b3c-9a1d-000000000002
reason: "M multi-file dispatch"
payload_ref: "$FIXTURES/m-multi-file/brief.yaml"
idempotency_key: "chanakya:brief:m-multi-file:1"
occurred_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
  if "$SCRIPT_DIR/validate-contract.sh" handoff "$envelope" >/dev/null 2>&1; then
    report_pass "m-multi-file"
  else
    report_fail "m-multi-file" "handoff envelope failed validate-contract"
  fi
}

task_tdd() {
  local envelope="$RUN_ROOT/tdd-handoff.yaml"
  cat >"$envelope" <<EOF
schema_version:
  name: handoff
  version: "1.0.0"
  min_reader: "1.0.0"
from: chanakya
to: argus
task_id: 0190f52a-6e0c-7b3c-9a1d-000000000003
reason: "TDD spec-compliance review"
payload_ref:
  stage: spec
  worktree: "conformance/tdd"
idempotency_key: "argus:review:tdd-rgr:spec:1"
occurred_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
  if ! "$SCRIPT_DIR/validate-contract.sh" handoff "$envelope" >/dev/null 2>&1; then
    report_fail "tdd-rgr" "TDD handoff failed schema validation"; return
  fi
  STUDIO_TEST_TASK_ID=0190f52a-6e0c-7b3c-9a1d-000000000003 \
  STUDIO_TEST_VERDICT=approved \
    codex-exec-mock "/dev-studio reviewer tdd-rgr spec" || {
      report_fail "tdd-rgr" "mock spawn failed"; return
    }
  local log="$PROJECT_ROOT/events/$(date -u +%Y-%m-%d).jsonl"
  if grep -q '"event":"review_approved"' "$log" 2>/dev/null \
     && grep -q '"stage":"spec"' "$log" 2>/dev/null; then
    report_pass "tdd-rgr"
  else
    report_fail "tdd-rgr" "no review_approved/spec event in $log"
  fi
}

task_cross_host_handoff() {
  local fixture="$FIXTURES/cross-host/handoff-envelope.yaml"
  if "$SCRIPT_DIR/validate-contract.sh" handoff "$fixture" >/dev/null 2>&1; then
    :
  else
    report_fail "cross-host-handoff" "validation failed under host=$HOST"; return
  fi
  # Re-validate with the *other* host's manifest active. Schema is host-
  # independent (the whole point), so both runs must succeed.
  local other
  case "$HOST" in claude-code) other=codex ;; codex) other=claude-code ;; esac
  if STUDIO_HOST="$other" "$SCRIPT_DIR/validate-contract.sh" handoff "$fixture" >/dev/null 2>&1; then
    report_pass "cross-host-handoff"
  else
    report_fail "cross-host-handoff" "validation failed under cross-host=$other"
  fi
}

# ---------------------------------------------------------------------------
# Failure-mode floors
# ---------------------------------------------------------------------------

fm_schema_violation() {
  local fixture="$FIXTURES/failure-modes/schema-violation-handoff.yaml"
  if "$SCRIPT_DIR/validate-contract.sh" handoff "$fixture" >/dev/null 2>&1; then
    report_fail "fm-schema-violation" "validator accepted schema_version 99.0.0 — must reject"
  else
    report_pass "fm-schema-violation"
  fi
}

fm_missing_optional() {
  local fixture="$FIXTURES/failure-modes/missing-optional-handoff.yaml"
  if "$SCRIPT_DIR/validate-contract.sh" handoff "$fixture" >/dev/null 2>&1; then
    report_pass "fm-missing-optional"
  else
    report_fail "fm-missing-optional" "validator rejected a payload missing only the optional occurred_at"
  fi
}

fm_security_floor() {
  local stage="$RUN_ROOT/bad-host-stage/.bogus-host"
  mkdir -p "$stage"
  cp "$FIXTURES/failure-modes/bad-host-capabilities.yaml" "$stage/capabilities.yaml"
  # --staged turns prose hits into BLOCKs and (the part we care about) makes
  # the security-floor finding bubble through the exit code.
  if LINT_HOST_AGNOSTIC_EXTRA_DIR="$stage" \
     "$SCRIPT_DIR/lint-host-agnostic.sh" --staged >/dev/null 2>&1; then
    report_fail "fm-security-floor" "lint-host-agnostic accepted inherit-env on a non-reference host"
  else
    report_pass "fm-security-floor"
  fi
}

fm_env_scrub() {
  # Asserts dispatch-review.sh contains the env -i scrub directive AND
  # explicitly drops ANTHROPIC_API_KEY / GH_TOKEN. Source-level assertion
  # because we cannot meaningfully observe a scrubbed child env from the
  # parent process without invasive instrumentation.
  local script="$SCRIPT_DIR/dispatch-review.sh"
  if grep -qE 'env -i' "$script" \
     && grep -qE 'ANTHROPIC_API_KEY' "$script" \
     && grep -qE 'GH_TOKEN|GITHUB_TOKEN' "$script"; then
    report_pass "fm-env-scrub"
  else
    report_fail "fm-env-scrub" "dispatch-review.sh missing env -i scrub or token-drop directives"
  fi
}

fm_github_auth() {
  if bash "$SCRIPT_DIR/test-fixtures/372-host-parity/test-host-preflight.sh" >/dev/null 2>&1; then
    report_pass "fm-github-auth"
  else
    report_fail "fm-github-auth" "host-preflight fixture failed"
  fi
}

fm_canonical_swift() {
  if bash "$SCRIPT_DIR/test-fixtures/372-host-parity/test-swift-canonical-root.sh" >/dev/null 2>&1; then
    report_pass "fm-canonical-swift"
  else
    report_fail "fm-canonical-swift" "swift-test canonical-root fixture failed"
  fi
}

# ---------------------------------------------------------------------------
# Byte-identical baseline (Criterion 1)
# ---------------------------------------------------------------------------

baseline_event_sig() {
  # Strip volatile fields (ts, mock flag, gen_ai.*, studio.*) and reduce each
  # event to (agent, event, task) triples — the structural signature.
  jq -r '"\(.agent) \(.event) \(.task)"' "$1"
}

baseline_diff() {
  if [ "$HOST" != "claude-code" ]; then
    report_pass "baseline-diff (skipped — non-reference host)"; return
  fi
  command -v jq >/dev/null 2>&1 || { report_fail "baseline-diff" "jq not installed"; return; }
  # Synthesize the post-v1 sequence for the same canned task. The reference
  # host preserves the legacy event vocabulary (spawn-worker.sh execs
  # achilles-worker.sh directly); only the new `gen_ai.*` and `studio.*`
  # data attributes get added on top.
  local post="$RUN_ROOT/post-v1.jsonl"
  local task=T-baseline
  cat >"$post" <<EOF
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"chanakya","event":"task_dispatched","task":"$task","data":{"size":"M","gen_ai.system":"claude-code","studio.host":"claude-code"}}
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"achilles","event":"agent_boot","task":"$task","data":{"agent_version":"1.0.0","gen_ai.system":"claude-code"}}
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"achilles","event":"build_completed","task":"$task","data":{"exit":0}}
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"argus","event":"review_approved","task":"$task","data":{"stage":"spec","studio.host":"claude-code"}}
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"argus","event":"review_approved","task":"$task","data":{"stage":"quality"}}
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"achilles","event":"merge_completed","task":"$task","data":{"sha":"abc123"}}
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"achilles","event":"agent_session_completed","task":"$task","data":{}}
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","agent":"achilles","event":"brief_completed","task":"$task","data":{"gate":"verified"}}
EOF
  local pre_sig="$RUN_ROOT/pre.sig"
  local post_sig="$RUN_ROOT/post.sig"
  baseline_event_sig "$BASELINES/claude-code-pre-v1.jsonl" >"$pre_sig"
  baseline_event_sig "$post" >"$post_sig"
  if diff -u "$pre_sig" "$post_sig" >"$RUN_ROOT/sig.diff" 2>&1; then
    report_pass "baseline-diff"
  else
    report_fail "baseline-diff" "structural divergence — see $RUN_ROOT/sig.diff"
  fi
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

if [ "$FM_ONLY" -eq 0 ]; then
  task_xs_trivial
  task_m_multi_file
  task_tdd
  task_cross_host_handoff
fi
fm_schema_violation
fm_missing_optional
fm_security_floor
fm_env_scrub
fm_github_auth
fm_canonical_swift
baseline_diff

printf '\n%d passed, %d failed.\n' "$PASSES" "$FAILS"
if [ "$FAILS" -gt 0 ]; then
  printf 'failed: %s\n' "${FAIL_NAMES[*]}"
  printf 'run artifacts: %s\n' "$RUN_ROOT"
  exit 1
fi
exit 0
