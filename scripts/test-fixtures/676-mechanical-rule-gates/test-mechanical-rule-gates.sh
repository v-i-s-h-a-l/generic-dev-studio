#!/usr/bin/env bash
# Regression coverage for deterministic chain rule-pack gate enforcement.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
GATES="$ROOT/scripts/studio-chain-rule-gates.sh"
RUNNER="$ROOT/scripts/studio-chain-runner.sh"
TMPROOT=$(mktemp -d -t mechanical-rule-gates-676.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"

repo="$TMPROOT/repo"
mkdir -p "$repo/scripts"
git -C "$TMPROOT" init -q repo
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Gate Fixture"
printf 'ok\n' >"$repo/README.md"
printf '#!/usr/bin/env bash\ntrue\n' >"$repo/scripts/safe.sh"
git -C "$repo" add README.md scripts/safe.sh
git -C "$repo" commit -q -m "initial"
git -C "$repo" branch -M main
source_sha=$(git -C "$repo" rev-parse main)

plan="$TMPROOT/plan.json"
jq -n \
  --arg source_sha "$source_sha" \
  --arg work_root "$TMPROOT/run-work" \
  '{
    schema_version:1,
    chains:[{
      name:"gate-fixture",
      base:"main",
      branch:"feature/gate-fixture",
      expected_source_sha:$source_sha,
      chain_worktree:($work_root + "/gate-fixture-feature"),
      issues:[{number:67601, issue_worktree:($work_root + "/gate-fixture-issue-67601")}]
    }]
  }' >"$plan"

audit="$TMPROOT/audit.jsonl"
"$GATES" --plan "$plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" --audit-log "$audit" --enforce-git-workflow >"$TMPROOT/pass.json"
jq -e '.status == "ok" and ([.checks[] | select(.id == "dirty_tree_and_index" and .status == "passed")] | length == 1)' "$TMPROOT/pass.json" >/dev/null \
  || fail "clean gate path did not pass"
[ "$(jq -c . "$audit" | wc -l | tr -d ' ')" -gt 0 ] || fail "audit log was not written"

printf 'dirty\n' >"$repo/dirty.txt"
if "$GATES" --plan "$plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" --audit-log "$TMPROOT/dirty-audit.jsonl" --enforce-git-workflow >"$TMPROOT/dirty.json"; then
  cat "$TMPROOT/dirty.json" >&2
  fail "dirty tree unexpectedly passed"
fi
jq -e '.status == "halt" and ([.failures[] | select(.id == "dirty_tree_and_index")] | length == 1)' "$TMPROOT/dirty.json" >/dev/null \
  || fail "dirty tree did not produce typed halt"

STUDIO_BYPASS_DIRTY_TREE_GATE=1 "$GATES" --plan "$plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" --audit-log "$TMPROOT/dirty-override-audit.jsonl" --enforce-git-workflow >"$TMPROOT/dirty-override.json"
jq -e '.status == "ok" and ([.overrides[] | select(.id == "dirty_tree_and_index" and .override_env == "STUDIO_BYPASS_DIRTY_TREE_GATE")] | length == 1)' "$TMPROOT/dirty-override.json" >/dev/null \
  || fail "dirty override path did not pass with override evidence"
rm -f "$repo/dirty.txt"

bad_plan="$TMPROOT/bad-plan.json"
jq '.chains[0].expected_source_sha = "0000000000000000000000000000000000000000" | .chains[0].issues[0].issue_worktree = "/tmp/outside-gate-root"' "$plan" >"$bad_plan"
if "$GATES" --plan "$bad_plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" --audit-log "$TMPROOT/bad-audit.jsonl" >"$TMPROOT/bad.json"; then
  cat "$TMPROOT/bad.json" >&2
  fail "bad source SHA/artifact root unexpectedly passed"
fi
jq -e '
  .status == "halt"
  and ([.failures[] | select(.id == "expected_source_branch_sha")] | length == 1)
  and ([.failures[] | select(.id == "artifact_root_construction")] | length == 1)
' "$TMPROOT/bad.json" >/dev/null || fail "bad plan did not fail expected gates"

STUDIO_BYPASS_SOURCE_SHA_GATE=1 STUDIO_BYPASS_ARTIFACT_ROOT_GATE=1 \
  "$GATES" --plan "$bad_plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" --audit-log "$TMPROOT/bad-override-audit.jsonl" >"$TMPROOT/bad-override.json"
jq -e '
  .status == "ok"
  and ([.overrides[] | select(.id == "expected_source_branch_sha")] | length == 1)
  and ([.overrides[] | select(.id == "artifact_root_construction")] | length == 1)
' "$TMPROOT/bad-override.json" >/dev/null || fail "bad plan override path did not pass"

STUDIO_DERIVED_DATA_CACHE_KEY="bad/key" \
  "$GATES" --plan "$plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" >"$TMPROOT/bad-cache.json" 2>/dev/null && fail "bad DerivedData cache key unexpectedly passed"
STUDIO_BYPASS_DERIVED_DATA_CACHE_KEY_GATE=1 STUDIO_DERIVED_DATA_CACHE_KEY="bad/key" \
  "$GATES" --plan "$plan" --repo "$repo" --expected-run-work-root "$TMPROOT/run-work" >"$TMPROOT/bad-cache-override.json"
jq -e '.status == "ok" and ([.overrides[] | select(.id == "derived_data_cache_key")] | length == 1)' "$TMPROOT/bad-cache-override.json" >/dev/null \
  || fail "DerivedData cache key override path did not pass"

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR"
cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{"number":$issue,"title":"Mechanical gate fixture $issue","body":"Exercise rule gates.","url":"https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/$issue","state":"OPEN"}
JSON
  exit 0
fi
printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

manifest="$TMPROOT/chain.yaml"
cat >"$manifest" <<'YAML'
schema_version: 1
chains:
  - name: mechanical-gates
    base: main
    branch: feature/mechanical-gates
    host: codex
    phase_review: off
    issues: [67602]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" TMPDIR="$TMPROOT/tmp/" "$RUNNER" "$manifest" --dry-run >"$TMPROOT/runner.out" 2>&1
grep -q 'Mechanical rule gates: `ok`' "$TMPROOT/runner.out" || {
  cat "$TMPROOT/runner.out" >&2
  fail "runner dry-run did not surface mechanical gate status"
}

printf 'PASS: mechanical rule gates\n'
