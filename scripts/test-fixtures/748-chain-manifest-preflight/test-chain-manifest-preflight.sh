#!/usr/bin/env bash
# Regression coverage for work-chain manifest compatibility and issue repo preflight.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
MANAGER="$ROOT/scripts/manager-work-chain.sh"
TMPROOT=$(mktemp -d -t chain-manifest-preflight-748.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
if ! command -v yq >/dev/null 2>&1; then
  printf 'SKIP: yq required for chain manifest preflight fixture\n'
  exit 0
fi

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
GH_LOG="$TMPROOT/gh.log"
mkdir -p "$BIN" "$HOME_DIR"
: > "$GH_LOG"

cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

printf '%s\n' "$*" >> "$GH_LOG"

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "Manifest preflight fixture $issue",
  "body": "Exercise manifest preflight behavior.",
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

planning_manifest="$TMPROOT/planning.yaml"
cat >"$planning_manifest" <<'YAML'
schema_version: 1
kind: studio-work-chain-plan
nodes:
  - id: T-R001
    kind: task
    label: Create the runnable issue
ready_node_ids: [T-R001]
validation:
  status: valid
YAML

if PATH="$BIN:$PATH" GH_LOG="$GH_LOG" HOME="$HOME_DIR" "$MANAGER" "$planning_manifest" >"$TMPROOT/planning.out" 2>&1; then
  cat "$TMPROOT/planning.out" >&2
  fail "planning manifest unexpectedly started"
fi
grep -q 'manifest/schema mismatch' "$TMPROOT/planning.out" || {
  cat "$TMPROOT/planning.out" >&2
  fail "planning manifest failure did not use schema mismatch wording"
}
grep -q 'planning artifacts must be converted before execution' "$TMPROOT/planning.out" || {
  cat "$TMPROOT/planning.out" >&2
  fail "planning manifest failure did not explain the conversion path"
}
if [ -d "$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs" ]; then
  find "$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs" -maxdepth 3 -print >&2
  fail "planning manifest created a chain run directory"
fi

PATH="$BIN:$PATH" GH_LOG="$GH_LOG" HOME="$HOME_DIR" "$MANAGER" --discover "$planning_manifest" >"$TMPROOT/discover.out" 2>&1
grep -q '## Non-Runnable Manifest Matches' "$TMPROOT/discover.out" || {
  cat "$TMPROOT/discover.out" >&2
  fail "discovery did not distinguish the planning manifest"
}
grep -q 'create or map GitHub issues' "$TMPROOT/discover.out" || {
  cat "$TMPROOT/discover.out" >&2
  fail "discovery did not explain required issue mapping"
}

project_repo="$TMPROOT/project"
mkdir -p "$project_repo"
git -C "$project_repo" init -q

missing_repo_manifest="$TMPROOT/missing-issue-repo.yaml"
cat >"$missing_repo_manifest" <<YAML
schema_version: 1
target_repo_root: $project_repo
chains:
  - name: missing-issue-repo
    base: main
    branch: feature/missing-issue-repo
    host: codex
    issues: [74801]
YAML

if PATH="$BIN:$PATH" GH_LOG="$GH_LOG" HOME="$HOME_DIR" "$RUNNER" "$missing_repo_manifest" --dry-run >"$TMPROOT/missing-repo.out" 2>&1; then
  cat "$TMPROOT/missing-repo.out" >&2
  fail "project manifest without issue_repo unexpectedly passed"
fi
grep -q 'issue repository is not explicit' "$TMPROOT/missing-repo.out" || {
  cat "$TMPROOT/missing-repo.out" >&2
  fail "missing issue_repo failure was not actionable"
}

project_manifest="$TMPROOT/project-chain.yaml"
cat >"$project_manifest" <<YAML
schema_version: 1
target_repo_root: $project_repo
issue_repo: example/project
chains:
  - name: project-chain
    base: main
    branch: feature/project-chain
    host: codex
    issues: [74801]
YAML

: > "$GH_LOG"
PATH="$BIN:$PATH" GH_LOG="$GH_LOG" HOME="$HOME_DIR" "$RUNNER" "$project_manifest" --dry-run >"$TMPROOT/project.out" 2>&1
grep -q 'Issue repo: `example/project`' "$TMPROOT/project.out" || {
  cat "$TMPROOT/project.out" >&2
  fail "plan did not report the manifest issue repo"
}
grep -q '^issue view 74801 --repo example/project ' "$GH_LOG" || {
  cat "$GH_LOG" >&2
  fail "issue lookup did not use the manifest issue repo"
}

printf 'PASS: chain manifest preflight\n'
