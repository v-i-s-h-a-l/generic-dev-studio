#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
TMPROOT=$(mktemp -d -t chain-provenance-749.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
if ! command -v yq >/dev/null 2>&1; then
  printf 'SKIP: yq required for chain provenance fixture\n'
  exit 0
fi

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR"

cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "Provenance fixture $issue",
  "body": "Exercise chain lifecycle provenance.",
  "url": "https://github.com/example/project/issues/$issue",
  "state": "OPEN"
}
JSON
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

manifest="$TMPROOT/provenance.yaml"
cat >"$manifest" <<'YAML'
schema_version: 1
issue_repo: example/project
chains:
  - name: provenance
    base: main
    branch: feature/provenance
    host: codex
    phase_review: off
    issues: [74901]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$RUNNER" "$manifest" --dry-run --yes >"$TMPROOT/provenance.out" 2>&1

state_path=$(sed -n 's/^- State: `\(.*\)`$/\1/p' "$TMPROOT/provenance.out" | head -1)
[ -n "$state_path" ] || {
  cat "$TMPROOT/provenance.out" >&2
  fail "missing state path in provenance dry run"
}

jq -e '
  .chains[0].issues[0] as $issue
  | ($issue.lifecycle_history | map(.state)) as $history
  | $issue.status == "completed"
  and $issue.lifecycle_state == "closed"
  and (["issue-created", "implementation-running", "implemented-local", "smoke-passed", "merged", "closed"] | all(.[]; . as $state | ($history | index($state)) != null))
  and $issue.provenance.issue.number == 74901
  and $issue.provenance.issue.repo == "example/project"
  and $issue.provenance.session.issue_run_id == $issue.issue_run_id
  and $issue.provenance.implementation.commit_after == "dry-run-after"
  and $issue.provenance.validation.validation_point == "runner-state"
  and $issue.provenance.merge.chain_commit == null
  and $issue.provenance.closure.pr_url == "<dry-run-pr-url>"
' "$state_path" >/dev/null || {
  jq '.chains[0].issues[0]' "$state_path" >&2
  fail "issue lifecycle/provenance state was incomplete"
}

audit_gap_manifest="$TMPROOT/done-without-issue.yaml"
cat >"$audit_gap_manifest" <<'YAML'
schema_version: 1
kind: studio-work-chain-plan
tasks:
  - id: T-DONE
    title: Locally finished without issue
    status: done
YAML

if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$RUNNER" "$audit_gap_manifest" --dry-run >"$TMPROOT/audit-gap.out" 2>&1; then
  cat "$TMPROOT/audit-gap.out" >&2
  fail "done planning artifact without issue mapping unexpectedly passed"
fi
grep -q 'audit gap' "$TMPROOT/audit-gap.out" || {
  cat "$TMPROOT/audit-gap.out" >&2
  fail "missing audit gap diagnostic"
}
grep -q 'done/implemented planning tasks without issue mappings are not authoritative' "$TMPROOT/audit-gap.out" || {
  cat "$TMPROOT/audit-gap.out" >&2
  fail "audit gap diagnostic did not explain provenance requirement"
}

printf 'PASS: chain provenance lifecycle\n'
