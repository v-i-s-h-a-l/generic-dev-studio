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

  if (cd "$root" && unset STUDIO_HOST && STUDIO_COMMIT_MSG_LINT_REPO_ROOT="$root" STUDIO_BYPASS_COMMIT_TRAILER_LINT="$bypass" "$LINT_SCRIPT" --file "$msg_file" >"$out" 2>&1); then
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

valid_message="feature: enforce structured commit metadata

Affected-Areas: commit hooks, release messages

Problem: Automated commits need consistent metadata for humans, release notes, and agents.

Solution: Require the structured commit sections and trailers.

Changelog: Commit messages now carry a release-ready summary.

Implementation notes: The commit-msg lint checks the canonical field labels.

Caveats: None.

Change-Type: feature
Studio-Host: codex
Co-authored-by: Codex <noreply@openai.com>"

compact_valid_message="feature: enforce compact commit metadata

Impact: Hosted commit lint now accepts the compact impact schema.

Areas: commit hooks, release messages

Release-Note: Commit messages now carry compact release-note metadata.

Why: Compact fields keep commit bodies shorter while preserving triage metadata.

Risk: low - accept-either transition preserves legacy commit producers.

Details: The lint keeps legacy verbose fields valid until producer migration completes.

Change-Type: feature
Studio-Host: codex
Co-authored-by: Codex <noreply@openai.com>"

codex_missing_coauthor_message="feature: enforce structured commit metadata

Affected-Areas: commit hooks, release messages

Problem: Automated commits need consistent metadata for humans, release notes, and agents.

Solution: Require the structured commit sections and trailers.

Changelog: Commit messages now carry a release-ready summary.

Implementation notes: The commit-msg lint checks the canonical field labels.

Caveats: None.

Change-Type: feature
Studio-Host: codex"

codex_bad_coauthor_message="feature: enforce structured commit metadata

Affected-Areas: commit hooks, release messages

Problem: Automated commits need consistent metadata for humans, release notes, and agents.

Solution: Require the structured commit sections and trailers.

Changelog: Commit messages now carry a release-ready summary.

Implementation notes: The commit-msg lint checks the canonical field labels.

Caveats: None.

Change-Type: feature
Studio-Host: codex
Co-authored-by: Codex <codex@openai.com>"

invalid_type_message="unknown: enforce structured commit metadata

Affected-Areas: commit hooks, release messages

Problem: Automated commits need consistent metadata for humans, release notes, and agents.

Solution: Require the structured commit sections and trailers.

Changelog: Commit messages now carry a release-ready summary.

Implementation notes: The commit-msg lint checks the canonical field labels.

Caveats: None.

Change-Type: unknown
Studio-Host: codex"

missing_host_message="docs: document structured commit metadata

Affected-Areas: commit docs

Problem: Commit metadata expectations were unclear.

Solution: Document the structured shape.

Changelog: Commit message docs now show the required release summary field.

Implementation notes: Documentation-only fixture.

Caveats: None.

Change-Type: docs"

missing_changelog_message="feature: enforce structured commit metadata

Affected-Areas: commit hooks, release messages

Problem: Automated commits need consistent metadata for humans, release notes, and agents.

Solution: Require the structured commit sections and trailers.

Implementation notes: The commit-msg lint checks the canonical field labels.

Caveats: None.

Change-Type: feature
Studio-Host: codex"

compact_missing_risk_message="feature: enforce compact commit metadata

Impact: Hosted commit lint now accepts the compact impact schema.

Areas: commit hooks, release messages

Release-Note: Commit messages now carry compact release-note metadata.

Why: Compact fields keep commit bodies shorter while preserving triage metadata.

Change-Type: feature
Studio-Host: codex"

compact_invalid_risk_message="feature: enforce compact commit metadata

Impact: Hosted commit lint now accepts the compact impact schema.

Areas: commit hooks, release messages

Release-Note: Commit messages now carry compact release-note metadata.

Why: Compact fields keep commit bodies shorter while preserving triage metadata.

Risk: urgent - no taxonomy value.

Change-Type: feature
Studio-Host: codex"

compact_risk_without_reason_message="feature: enforce compact commit metadata

Impact: Hosted commit lint now accepts the compact impact schema.

Areas: commit hooks, release messages

Release-Note: Commit messages now carry compact release-note metadata.

Why: Compact fields keep commit bodies shorter while preserving triage metadata.

Risk: low

Change-Type: feature
Studio-Host: codex"

bad_subject_message="Structured metadata without taxonomy prefix

Affected-Areas: commit hooks, release messages

Problem: Automated commits need consistent metadata for humans, release notes, and agents.

Solution: Require the structured commit sections and trailers.

Changelog: Commit messages now carry a release-ready summary.

Implementation notes: The commit-msg lint checks the canonical field labels.

Caveats: None.

Change-Type: feature
Studio-Host: codex"

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
run_case "compact_valid_automation" 0 "$automation_repo" "$compact_valid_message" ""
run_case "codex_missing_coauthor_warns" 0 "$automation_repo" "$codex_missing_coauthor_message" "Codex-hosted commits should include GitHub-visible credit"
run_case "codex_bad_coauthor_warns" 0 "$automation_repo" "$codex_bad_coauthor_message" "Codex co-author trailer should be exactly"
run_case "invalid_change_type_fails" 1 "$automation_repo" "$invalid_type_message" "invalid Change-Type trailer: unknown"
run_case "missing_host_fails_in_automation" 1 "$automation_repo" "$missing_host_message" "missing trailer Studio-Host"
run_case "missing_changelog_fails_in_automation" 1 "$automation_repo" "$missing_changelog_message" "missing required commit metadata"
run_case "compact_missing_risk_fails_in_automation" 1 "$automation_repo" "$compact_missing_risk_message" "Missing compact: Risk"
run_case "compact_invalid_risk_fails_in_automation" 1 "$automation_repo" "$compact_invalid_risk_message" "invalid Risk field"
run_case "compact_risk_without_reason_fails_in_automation" 1 "$automation_repo" "$compact_risk_without_reason_message" "plus a short reason"
run_case "bad_subject_fails_in_automation" 1 "$automation_repo" "$bad_subject_message" "commit subject must start with 'feature: '"
run_case "missing_host_warns_for_human" 0 "$human_repo" "$missing_host_message" "passed with"
run_case "compact_missing_risk_warns_for_human" 0 "$human_repo" "$compact_missing_risk_message" "passed with"
run_case "bypass_allows_hard_failure_case" 0 "$automation_repo" "$missing_host_message" "commit trailer lint bypassed via STUDIO_BYPASS_COMMIT_TRAILER_LINT=1" 1

printf 'PASS: commit-message lint fixture suite\n'
