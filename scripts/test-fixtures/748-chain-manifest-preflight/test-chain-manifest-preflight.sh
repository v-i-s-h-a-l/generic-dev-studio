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

auto_bypass_manifest="$TMPROOT/auto-bypass-chain.yaml"
cat >"$auto_bypass_manifest" <<YAML
schema_version: 1
target_repo_root: $project_repo
issue_repo: example/project
chains:
  - name: auto-bypass-chain
    base: main
    branch: feature/auto-bypass-chain
    host: auto
    issues: [74802]
YAML

: > "$GH_LOG"
PATH="$BIN:$PATH" GH_LOG="$GH_LOG" HOME="$HOME_DIR" STUDIO_BYPASS_AUTO_HOST_ELIGIBILITY=1 "$RUNNER" "$auto_bypass_manifest" --dry-run >"$TMPROOT/auto-bypass.out" 2>&1
grep -q 'STUDIO_BYPASS_AUTO_HOST_ELIGIBILITY' "$TMPROOT/auto-bypass.out" || {
  cat "$TMPROOT/auto-bypass.out" >&2
  fail "auto host bypass did not report the documented bypass env"
}
grep -q "Host: \`claude-code\`" "$TMPROOT/auto-bypass.out" || {
  cat "$TMPROOT/auto-bypass.out" >&2
  fail "auto host bypass did not select the first worker profile as runner host"
}
if grep -q 'DRY-RUN host_eligibility_check' "$TMPROOT/auto-bypass.out"; then
  cat "$TMPROOT/auto-bypass.out" >&2
  fail "auto host bypass still planned an eligibility smoke check"
fi
if grep -q 'STUDIO_BYPASS_HOST_RESOLVER' "$TMPROOT/auto-bypass.out"; then
  cat "$TMPROOT/auto-bypass.out" >&2
  fail "auto host bypass leaked the retired bypass env name"
fi

v2_manifest="$TMPROOT/v2-chain.yaml"
cat >"$v2_manifest" <<YAML
schema_version: 1
target_repo_root: $project_repo
issue_repo: example/project
chains:
  - name: v2-chain
    base_ref: main
    independent: false
    branch: feature/v2-chain
    host: codex
    issues: [74803]
YAML

: > "$GH_LOG"
PATH="$BIN:$PATH" GH_LOG="$GH_LOG" HOME="$HOME_DIR" "$RUNNER" "$v2_manifest" --dry-run >"$TMPROOT/v2.out" 2>&1
grep -qF -- '- Source branch: `main`' "$TMPROOT/v2.out" || {
  cat "$TMPROOT/v2.out" >&2
  fail "v2 base_ref was not resolved as the source branch"
}
grep -qF -- '- Expected base SHA: `not pinned`' "$TMPROOT/v2.out" || {
  cat "$TMPROOT/v2.out" >&2
  fail "explain_plan should surface 'not pinned' when v2 base_sha is omitted"
}
grep -qF -- '- Independent: `false`' "$TMPROOT/v2.out" || {
  cat "$TMPROOT/v2.out" >&2
  fail "independent flag was not surfaced in explain_plan output"
}

conflict_manifest="$TMPROOT/conflict-chain.yaml"
cat >"$conflict_manifest" <<YAML
schema_version: 1
target_repo_root: $project_repo
issue_repo: example/project
chains:
  - name: conflict-chain
    base_ref: main
    source_branch: develop
    branch: feature/conflict-chain
    host: codex
    issues: [74804]
YAML

if PATH="$BIN:$PATH" GH_LOG="$GH_LOG" HOME="$HOME_DIR" "$RUNNER" "$conflict_manifest" --dry-run >"$TMPROOT/conflict.out" 2>&1; then
  cat "$TMPROOT/conflict.out" >&2
  fail "v1/v2 base ref conflict unexpectedly passed"
fi
grep -q 'manifest_branch_discipline_conflict' "$TMPROOT/conflict.out" || {
  cat "$TMPROOT/conflict.out" >&2
  fail "v1/v2 base ref conflict did not emit typed manifest_branch_discipline_conflict"
}

sha_conflict_manifest="$TMPROOT/sha-conflict-chain.yaml"
cat >"$sha_conflict_manifest" <<YAML
schema_version: 1
target_repo_root: $project_repo
issue_repo: example/project
chains:
  - name: sha-conflict-chain
    base_ref: main
    base_sha: 0123456789abcdef0123456789abcdef01234567
    expected_source_sha: fedcba9876543210fedcba9876543210fedcba98
    branch: feature/sha-conflict-chain
    host: codex
    issues: [74805]
YAML

if PATH="$BIN:$PATH" GH_LOG="$GH_LOG" HOME="$HOME_DIR" "$RUNNER" "$sha_conflict_manifest" --dry-run >"$TMPROOT/sha-conflict.out" 2>&1; then
  cat "$TMPROOT/sha-conflict.out" >&2
  fail "v1/v2 SHA conflict unexpectedly passed"
fi
grep -q 'manifest_branch_discipline_conflict' "$TMPROOT/sha-conflict.out" || {
  cat "$TMPROOT/sha-conflict.out" >&2
  fail "v1/v2 SHA conflict did not emit typed manifest_branch_discipline_conflict"
}

independent_conflict_manifest="$TMPROOT/independent-conflict-chain.yaml"
cat >"$independent_conflict_manifest" <<YAML
schema_version: 1
target_repo_root: $project_repo
issue_repo: example/project
chains:
  - name: independent-conflict-chain
    base_ref: main
    independent: true
    parent_branch: feature/parent
    branch: feature/independent-conflict-chain
    host: codex
    issues: [74806]
YAML

if PATH="$BIN:$PATH" GH_LOG="$GH_LOG" HOME="$HOME_DIR" "$RUNNER" "$independent_conflict_manifest" --dry-run >"$TMPROOT/independent-conflict.out" 2>&1; then
  cat "$TMPROOT/independent-conflict.out" >&2
  fail "independent=true with parent_branch unexpectedly passed"
fi
grep -q 'manifest_branch_discipline_conflict' "$TMPROOT/independent-conflict.out" || {
  cat "$TMPROOT/independent-conflict.out" >&2
  fail "independent=true + parent_branch did not emit typed manifest_branch_discipline_conflict"
}

printf 'PASS: chain manifest preflight\n'
