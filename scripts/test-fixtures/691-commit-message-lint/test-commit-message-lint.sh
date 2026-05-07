#!/usr/bin/env bash
# Verifies commit-message trailer lint behavior for automated and human-authored paths.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t commit-message-lint-691.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

LINT_SCRIPT="$ROOT/scripts/lint-commit-message.sh"
if [ ! -x "$LINT_SCRIPT" ]; then
  printf 'FAIL: missing lint script %s\n' "$LINT_SCRIPT" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'FAIL: jq is required for these fixtures\n' >&2
  exit 1
fi

run_case() {
  local case_name="$1"
  local expect_rc="$2"
  local root="$3"
  local message="$4"
  local expect_match="$5"
  local bypass="${6:-0}"

  local msg_file="$TMPROOT/$case_name.msg"
  local out="$TMPROOT/$case_name.out"
  printf '%s\n' "$message" > "$msg_file"

  if (cd "$root" && STUDIO_COMMIT_MSG_LINT_REPO_ROOT="$root" STUDIO_BYPASS_COMMIT_TRAILER_LINT="$bypass" "$LINT_SCRIPT" --file "$msg_file" >"$out" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne "$expect_rc" ]; then
    printf 'FAIL: %s expected rc=%s but got %s\n' "$case_name" "$expect_rc" "$rc" >&2
    sed -n '1,120p' "$out" >&2 || true
    exit 1
  fi
  if [ -n "$expect_match" ] && ! grep -Fq "$expect_match" "$out"; then
    printf 'FAIL: %s expected output match %q\n' "$case_name" "$expect_match" >&2
    sed -n '1,120p' "$out" >&2 || true
    exit 1
  fi
  printf 'PASS: %s\n' "$case_name"
}

valid_message="Valid commit

Change-Type: feature
Studio-Host: codex"

invalid_type_message="Invalid change-type

Change-Type: unknown
Studio-Host: codex"

missing_host_message="Missing host metadata

Change-Type: docs"

automation_repo="$TMPROOT/automation"
mkdir -p "$automation_repo/.studio"
cat > "$automation_repo/.studio/chain-task-start.json" <<'JSON'
{
  "ownership": {
    "host": "codex"
  }
}
JSON

human_repo="$TMPROOT/human"
mkdir -p "$human_repo"

run_case "valid_automation" 0 "$automation_repo" "$valid_message" ""
run_case "invalid_change_type_fails" 1 "$automation_repo" "$invalid_type_message" "invalid Change-Type trailer: unknown"
run_case "missing_host_fails_in_automation" 1 "$automation_repo" "$missing_host_message" "missing trailer Studio-Host"
run_case "missing_host_warns_for_human" 0 "$human_repo" "$missing_host_message" "passed with 1 warning(s)"
run_case "bypass_allows_hard_failure_case" 0 "$automation_repo" "$missing_host_message" "commit trailer lint bypassed via STUDIO_BYPASS_COMMIT_TRAILER_LINT=1" 1

printf 'PASS: commit-message lint fixture suite\n'
