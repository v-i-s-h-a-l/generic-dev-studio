#!/usr/bin/env bash
# Regression coverage for source-branch targeted chain execution.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
GATES="$ROOT/scripts/studio-chain-rule-gates.sh"
SCHEMA="$ROOT/core/v2/schemas/chain-manifest.schema.json"
TMPROOT=$(mktemp -d -t source-branch-chain-664.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
command -v yq >/dev/null 2>&1 || fail "yq required"

jq -e '
  ."$defs".chain.properties.source_branch.default == "main"
  and ."$defs".chain.properties.base.default == "main"
  and ."$defs".chain.properties.expected_source_sha.type == "string"
' "$SCHEMA" >/dev/null || fail "chain manifest schema missing source-branch fields"

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "Source branch fixture $issue",
  "body": "Exercise source-branch chain execution.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/$issue",
  "state": "OPEN"
}
JSON
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

manifest="$TMPROOT/source-chain.yaml"
cat > "$manifest" <<'YAML'
schema_version: 1
chains:
  - name: source-branch-fixture
    source_branch: feature/source-fixture
    branch: feature/source-branch-fixture
    host: codex
    phase_review: off
    issues: [66401]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$RUNNER" "$manifest" --dry-run > "$TMPROOT/dry-run.out" 2>&1
grep -Fq 'Source branch: `feature/source-fixture`' "$TMPROOT/dry-run.out" \
  || fail "dry-run plan did not surface source branch"
grep -Fq 'Planned PR: base `feature/source-fixture`, head `feature/source-branch-fixture`' "$TMPROOT/dry-run.out" \
  || fail "dry-run plan did not use source branch as PR base"
grep -q 'DRY-RUN git worktree add -B feature/source-branch-fixture .* origin/feature/source-fixture' "$TMPROOT/dry-run.out" \
  || fail "dry-run did not create chain branch from source branch"
grep -q 'DRY-RUN gh pr create --base feature/source-fixture --head feature/source-branch-fixture' "$TMPROOT/dry-run.out" \
  || fail "dry-run PR creation did not target source branch"

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$RUNNER" "$manifest" > "$TMPROOT/plan.out" 2>&1
state_path=$(sed -n 's/^- State: `\(.*\)`$/\1/p' "$TMPROOT/plan.out" | head -1)
[ -n "$state_path" ] || fail "default plan did not print state path"
jq -e '
  .status == "planned"
  and .chains[0].source_branch == "feature/source-fixture"
  and .chains[0].base == "feature/source-fixture"
' "$state_path" >/dev/null || fail "planned state did not persist selected source branch"

run_id=$(jq -r '.run_id' "$state_path")
PATH="$BIN:$PATH" HOME="$HOME_DIR" "$RUNNER" --resume "$run_id" --dry-run > "$TMPROOT/resume.out" 2>&1
grep -Fq 'Source branch: `feature/source-fixture`' "$TMPROOT/resume.out" \
  || fail "resume dry-run did not preserve source branch"
grep -q 'DRY-RUN gh pr create --base feature/source-fixture --head feature/source-branch-fixture' "$TMPROOT/resume.out" \
  || fail "resume dry-run did not preserve PR base"

conflict_manifest="$TMPROOT/source-conflict.yaml"
cat > "$conflict_manifest" <<'YAML'
schema_version: 1
chains:
  - name: source-conflict
    source_branch: feature/source-fixture
    base: main
    branch: feature/source-conflict
    host: codex
    issues: [66401]
YAML
if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$RUNNER" "$conflict_manifest" --dry-run > "$TMPROOT/conflict.out" 2>&1; then
  cat "$TMPROOT/conflict.out" >&2
  fail "conflicting source_branch/base manifest unexpectedly passed"
fi
grep -q 'conflicting source branch fields' "$TMPROOT/conflict.out" \
  || fail "conflicting source branch failure was not explained"

same_branch_manifest="$TMPROOT/source-same-branch.yaml"
cat > "$same_branch_manifest" <<'YAML'
schema_version: 1
chains:
  - name: source-same-branch
    source_branch: feature/source-same-branch
    branch: feature/source-same-branch
    host: codex
    issues: [66401]
YAML
if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$RUNNER" "$same_branch_manifest" --dry-run > "$TMPROOT/same.out" 2>&1; then
  cat "$TMPROOT/same.out" >&2
  fail "same source/chain branch manifest unexpectedly passed"
fi
grep -q 'chain branch must not equal source branch' "$TMPROOT/same.out" \
  || fail "same source/chain branch failure was not explained"

repo="$TMPROOT/repo"
git init -q "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Source Branch Fixture"
mkdir -p "$repo/scripts"
printf 'main\n' > "$repo/README.md"
printf '#!/usr/bin/env bash\ntrue\n' > "$repo/scripts/safe.sh"
git -C "$repo" add README.md scripts/safe.sh
git -C "$repo" commit -q -m "main"
git -C "$repo" branch -M main
git -C "$repo" checkout -q -b feature/source-target
printf 'source\n' > "$repo/source.txt"
git -C "$repo" add source.txt
git -C "$repo" commit -q -m "source"
source_sha=$(git -C "$repo" rev-parse HEAD)
main_sha=$(git -C "$repo" rev-parse main)

plan="$TMPROOT/source-plan.json"
jq -n \
  --arg source_sha "$source_sha" \
  --arg work_root "$TMPROOT/run-work" \
  '{
    schema_version: 1,
    chains: [{
      name: "source-gate",
      base: "main",
      source_branch: "feature/source-target",
      expected_source_sha: $source_sha,
      branch: "feature/source-gate",
      chain_worktree: ($work_root + "/source-gate-feature"),
      issues: [{number: 66401, issue_worktree: ($work_root + "/source-gate-issue-66401")}]
    }]
  }' > "$plan"
"$GATES" --plan "$plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" > "$TMPROOT/gates.json"
jq -e '
  .status == "ok"
  and ([.checks[] | select(.id == "expected_source_branch_sha" and .status == "passed")] | length == 1)
' "$TMPROOT/gates.json" >/dev/null || fail "source-branch expected SHA gate did not pass"

bad_plan="$TMPROOT/source-plan-bad.json"
jq --arg main_sha "$main_sha" '.chains[0].expected_source_sha = $main_sha' "$plan" > "$bad_plan"
if "$GATES" --plan "$bad_plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" > "$TMPROOT/bad-gates.json"; then
  cat "$TMPROOT/bad-gates.json" >&2
  fail "stale source SHA gate unexpectedly passed"
fi
jq -e '
  .status == "halt"
  and ([.failures[] | select(.id == "expected_source_branch_sha" and (.detail | contains("feature/source-target")))] | length == 1)
' "$TMPROOT/bad-gates.json" >/dev/null || fail "stale source SHA failure did not name source branch"

printf 'PASS: source-branch chain execution\n'
