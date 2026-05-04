#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-parent-finalize-584.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

# shellcheck source=../../../lib-chain-git.sh
. "$ROOT/scripts/lib-chain-git.sh"

PRIVATE_REPO="$TMPROOT/private-only"
mkdir -p "$PRIVATE_REPO"
git -C "$PRIVATE_REPO" init -q
git -C "$PRIVATE_REPO" config user.email studio@example.invalid
git -C "$PRIVATE_REPO" config user.name "Studio Test"
printf 'base\n' > "$PRIVATE_REPO/README.md"
git -C "$PRIVATE_REPO" add README.md
git -C "$PRIVATE_REPO" commit -q -m "base"
mkdir -p "$PRIVATE_REPO/.studio" "$PRIVATE_REPO/.git2" "$PRIVATE_REPO/.git-protected"
printf '{}\n' > "$PRIVATE_REPO/.studio/chain-worker-summary.json"
printf '[core]\n' > "$PRIVATE_REPO/.git2/config"
printf 'ref: refs/heads/main\n' > "$PRIVATE_REPO/.git-protected/HEAD"
if chain_git_parent_finalize_has_public_diff "$PRIVATE_REPO"; then
  fail "private checkpoint and git metadata dirs counted as public diff"
fi

REPO="$TMPROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email studio@example.invalid
git -C "$REPO" config user.name "Studio Test"
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "base"

mkdir -p "$REPO/.studio"
cat > "$REPO/.studio/chain-worker-summary.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "completion",
  "status": "blocked",
  "issue_number": 584,
  "issue_title": "Parent finalize fixture",
  "commit_before": "base",
  "commit_after": null,
  "blocked_reason": "Unable to stage or commit: filesystem denies writes inside .git creating .git/index.lock with Operation not permitted.",
  "tests": [{"command": "fixture", "outcome": "passed"}],
  "lints": [
    {"command": "git diff --check", "outcome": "passed_with_warning"},
    {"command": "git diff --cached --check in alternate git dir", "outcome": "passed_before_alternate_commit"},
    {
      "command": "scripts/lint-host-agnostic.sh",
      "outcome": "passed_with_warning",
      "warning": "W_ARGUS_SECRET_SCOPE:.codex/capabilities.yaml:secret_scope=cwd-only"
    }
  ],
  "builds": [],
  "carryover": [
    "Existing W_ARGUS_SECRET_SCOPE lint warning was captured; no implementation scope blocker."
  ],
  "lessons": [
    "A benign secret-scope lint warning must not block parent finalization by itself."
  ]
}
JSON
printf 'base\nchange\n' > "$REPO/README.md"
printf 'new\n' > "$REPO/runtime.sh"
mkdir -p "$REPO/.git2" "$REPO/.git-protected"
printf '[core]\n' > "$REPO/.git2/config"
printf 'ref: refs/heads/main\n' > "$REPO/.git-protected/HEAD"
printf 'node_modules/\n' > "$REPO/.gitignore"

chain_git_parent_finalize_summary_eligible "$REPO/.studio/chain-worker-summary.json" \
  || fail "git metadata summary was not eligible"
chain_git_parent_finalize_summary_reports_failure "$REPO/.studio/chain-worker-summary.json" \
  || fail "blocked summary was not reported as failure"
[ "$(chain_git_parent_finalize_effective_worker_rc 0 "$REPO/.studio/chain-worker-summary.json")" = "1" ] \
  || fail "summary-reported failure did not override zero host rc"
[ "$(chain_git_parent_finalize_reconciled_worker_rc 0 1 false)" = "1" ] \
  || fail "effective worker rc was not preserved before parent finalize"
[ "$(chain_git_parent_finalize_reconciled_worker_rc 0 1 true)" = "0" ] \
  || fail "effective worker rc was reapplied after parent finalize"
[ "$(chain_git_parent_finalize_reconciled_worker_rc 1 1 true)" = "0" ] \
  || fail "child worker rc was not cleared after parent finalize"
cat "$REPO/.studio/chain-worker-summary.json" | jq '.exit_code = 0' > "$TMPROOT/status-only-summary.json"
[ "$(chain_git_parent_finalize_effective_worker_rc 0 "$TMPROOT/status-only-summary.json")" = "1" ] \
  || fail "blocked status did not override zero host rc"
chain_git_parent_finalize_has_public_diff "$REPO" \
  || fail "public diff was not detected"
chain_git_parent_finalize_issue_commit "$REPO" 584 "$REPO/.studio/chain-worker-summary.json" \
  || fail "parent finalize did not commit"

git -C "$REPO" log -1 --format=%B | grep -q 'Closes #584' \
  || fail "parent commit did not close issue"
git -C "$REPO" log -1 --format=%s | grep -qx 'Parent finalize fixture (#584)' \
  || fail "parent commit subject did not use issue title"
git -C "$REPO" diff-tree --no-commit-id --name-only -r HEAD | grep -qx 'README.md' \
  || fail "README diff missing from parent commit"
git -C "$REPO" diff-tree --no-commit-id --name-only -r HEAD | grep -qx 'runtime.sh' \
  || fail "new file missing from parent commit"
git -C "$REPO" diff-tree --no-commit-id --name-only -r HEAD | grep -qx '.gitignore' \
  || fail ".gitignore diff missing from parent commit"
if git -C "$REPO" diff-tree --no-commit-id --name-only -r HEAD | grep -q '^.studio/'; then
  fail "private .studio artifact was committed"
fi
if git -C "$REPO" diff-tree --no-commit-id --name-only -r HEAD | grep -Eq '^\.git(2|-protected)/'; then
  fail "private git metadata dir was committed"
fi

PAYLOAD=$(chain_git_parent_finalize_event_payload "$REPO/.studio/chain-worker-summary.json" base "$(git -C "$REPO" rev-parse HEAD)" codex)
printf '%s\n' "$PAYLOAD" | jq -e '
  .summary
  and .commit_before == "base"
  and (.commit_after | length == 40)
  and .worker_host == "codex"
  and .reason == "worker_git_metadata_unwritable"
' >/dev/null || fail "parent finalize event payload malformed"

mkdir -p "$TMPROOT/bad/.studio"
cat > "$TMPROOT/bad/.studio/chain-worker-summary.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "completion",
  "status": "blocked",
  "blocked_reason": "Required review failed.",
  "tests": [{"command": "fixture", "outcome": "passed"}]
}
JSON
if chain_git_parent_finalize_summary_eligible "$TMPROOT/bad/.studio/chain-worker-summary.json"; then
  fail "non-git blocker was eligible"
fi

mkdir -p "$TMPROOT/failing/.studio"
cat > "$TMPROOT/failing/.studio/chain-worker-summary.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "completion",
  "status": "blocked",
  "blocked_reason": "Unable to stage or commit: .git/index.lock Operation not permitted.",
  "tests": [{"command": "fixture", "outcome": "failed"}]
}
JSON
if chain_git_parent_finalize_summary_eligible "$TMPROOT/failing/.studio/chain-worker-summary.json"; then
  fail "failing checks were eligible"
fi

mkdir -p "$TMPROOT/unknown-outcome/.studio"
cat > "$TMPROOT/unknown-outcome/.studio/chain-worker-summary.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "completion",
  "status": "blocked",
  "blocked_reason": "Unable to stage or commit: .git/index.lock Operation not permitted.",
  "tests": [{"command": "fixture", "outcome": "passed_after_retry"}]
}
JSON
if chain_git_parent_finalize_summary_eligible "$TMPROOT/unknown-outcome/.studio/chain-worker-summary.json"; then
  fail "unknown passed_* outcome was eligible"
fi

mkdir -p "$TMPROOT/secret/.studio"
cat > "$TMPROOT/secret/.studio/chain-worker-summary.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "completion",
  "status": "blocked",
  "blocked_reason": "Unable to stage or commit: .git/index.lock Operation not permitted.",
  "tests": [{"command": "fixture", "outcome": "passed"}],
  "carryover": ["Potential secret exposure needs review before commit."]
}
JSON
if chain_git_parent_finalize_summary_eligible "$TMPROOT/secret/.studio/chain-worker-summary.json"; then
  fail "real secret blocker was eligible"
fi

printf 'PASS: chain parent-finalize commit fallback\n'
