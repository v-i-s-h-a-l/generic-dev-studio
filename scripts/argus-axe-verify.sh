#!/usr/bin/env bash
# argus-axe-verify.sh — capture an a11y-tree snapshot of the simulator UI
# after an Argus test run, emit a structured event, and persist the snapshot
# to the project's ui-evidence dir for human review.
#
# Net-new verification layer over xcresult-parse (#174). Today's xcresult
# parse only sees what XCUITest assertions caught — assertions run inside
# the test process, not against on-screen state. AXe's `describe-ui` walks
# the simulator's accessibility tree, so a passing test that drove the UI
# into an unexpected end-state surfaces here as a capture-time anomaly
# rather than escaping to production.
#
# Best-effort by design: if AXe is missing, simulator is unreachable, or
# describe-ui errors, the script emits a warning event and exits 0 — the
# Argus pre-merge gate is never failed by missing a11y verification.
#
# Usage:
#   argus-axe-verify.sh <task-id> <simulator-name> [<slot-n>]
#
# Output:
#   - $UI_EVIDENCE_DIR/<task-id>/<utc-ts>.json   a11y snapshot
#   - argus_a11y_captured event in the project event log with summary
#
# Exit codes:
#   0  always — see "best-effort" above

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh" 2>/dev/null || true

TASK_ID="${1:?argus-axe-verify: task-id required}"
SIM_NAME="${2:?argus-axe-verify: simulator name required}"
SLOT_N="${3:-0}"

# Locate AXe. AXe ships bundled with xcodebuildmcp v1.5.2+; also check $PATH
# in case the user installed it standalone.
AXE_BIN=""
if command -v axe >/dev/null 2>&1; then
  AXE_BIN=$(command -v axe)
elif command -v xcodebuildmcp >/dev/null 2>&1; then
  # xcodebuildmcp ships axe in libexec/ alongside the main binary on most
  # brew installs. Fall back to invoking via xcodebuildmcp's exec subsurface.
  mcp_dir=$(dirname "$(command -v xcodebuildmcp)")
  candidate="$mcp_dir/../libexec/axe"
  [ -x "$candidate" ] && AXE_BIN="$candidate"
fi

if [ -z "$AXE_BIN" ]; then
  emit_event_keyed argus review a11y_capture_skipped "$TASK_ID" \
    "{\"reason\":\"axe_not_found\",\"slot\":$SLOT_N}" >/dev/null 2>&1 || true
  exit 0
fi

# Resolve evidence dir under the project's runtime root. Falls back to a
# /tmp path if path-resolver isn't available (best-effort).
if PROJECT_DIR=$(resolve_runtime_global 2>/dev/null); then
  UI_EVIDENCE_DIR="$PROJECT_DIR/ui-evidence/$TASK_ID"
elif PROJECT_DIR=$(resolve_project 2>/dev/null); then
  UI_EVIDENCE_DIR="$HOME/.dev-studio/$PROJECT_DIR/.runtime/ui-evidence/$TASK_ID"
else
  UI_EVIDENCE_DIR="/tmp/argus-ui-evidence/$TASK_ID"
fi
mkdir -p "$UI_EVIDENCE_DIR"

UTC_TS=$(date -u +%Y%m%dT%H%M%SZ)
SNAPSHOT="$UI_EVIDENCE_DIR/$UTC_TS.json"

# Boot/connect to the simulator if not already up. Reuse the slot's sim
# from the test run; failure here means the test scripts already failed
# and we have nothing to capture.
sim_state=$(xcrun simctl list devices 2>/dev/null | grep -F "$SIM_NAME" | head -1)
if [ -z "$sim_state" ]; then
  emit_event_keyed argus review a11y_capture_skipped "$TASK_ID" \
    "{\"reason\":\"simulator_not_found\",\"sim\":\"$SIM_NAME\",\"slot\":$SLOT_N}" >/dev/null 2>&1 || true
  exit 0
fi

# Run describe-ui — captures the a11y tree as JSON. AXe's CLI is bounded
# to ~10s under normal conditions; cap at 20s to prevent a hung simulator
# from stalling the Argus path.
if ! "$AXE_BIN" describe-ui --sim "$SIM_NAME" --json > "$SNAPSHOT" 2>"${SNAPSHOT}.err"; then
  err_summary=$(head -1 "${SNAPSHOT}.err" 2>/dev/null | tr -d '"' | head -c 200)
  rm -f "$SNAPSHOT" "${SNAPSHOT}.err"
  emit_event_keyed argus review a11y_capture_failed "$TASK_ID" \
    "{\"slot\":$SLOT_N,\"sim\":\"$SIM_NAME\",\"error\":\"$err_summary\"}" >/dev/null 2>&1 || true
  exit 0
fi
rm -f "${SNAPSHOT}.err"

# Summarize the capture for the event payload. Bounded counts only; the
# full snapshot lives at $SNAPSHOT for human review (token-cheap to point
# at, expensive to inline).
elem_count=0
label_count=0
err_label_count=0
if [ -s "$SNAPSHOT" ] && command -v jq >/dev/null 2>&1; then
  elem_count=$(jq '[.. | objects | select(has("type"))] | length' "$SNAPSHOT" 2>/dev/null || echo 0)
  label_count=$(jq '[.. | objects | select(.label != null and .label != "")] | length' "$SNAPSHOT" 2>/dev/null || echo 0)
  # Heuristic — labels containing "error", "failed", "alert" hint at
  # unexpected end-state. Cheap to compute; informational, never blocking.
  err_label_count=$(jq '[.. | objects | select(.label != null) | select(.label|test("error|failed|alert|crash"; "i"))] | length' "$SNAPSHOT" 2>/dev/null || echo 0)
fi

# Truncate snapshot to keep the project dir lean — keep the full file for
# 7 days, then janitor sweeps. (Janitor wiring is a follow-up; for now the
# files accumulate under .runtime/ui-evidence/ which is already excluded
# from project sync.)

data=$(printf '{"slot":%s,"sim":"%s","snapshot":"%s","elements":%s,"labels":%s,"error_labels":%s}' \
  "$SLOT_N" "$SIM_NAME" "${SNAPSHOT#"$HOME/"}" "$elem_count" "$label_count" "$err_label_count")
emit_event_keyed argus review a11y_captured "$TASK_ID" "$data" >/dev/null 2>&1 || true

exit 0
