#!/usr/bin/env bash
# Verifies sequential chain leaves carry completed commits into later leaves.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-sequential-integration.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

. "$ROOT/scripts/lib-chain-git.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

REPO="$TMPROOT/repo"
CHAIN_WORKTREE="$TMPROOT/chain"
ISSUE_ONE="$TMPROOT/issue-one"
ISSUE_TWO="$TMPROOT/issue-two"

git init -q "$REPO"
git -C "$REPO" config user.name "Fixture"
git -C "$REPO" config user.email "fixture@example.com"
printf 'base\n' > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -q -m "base"
git -C "$REPO" branch -M main
git -C "$REPO" worktree add -q -B feature/chain "$CHAIN_WORKTREE" main

chain_git_prepare_issue_workspace "$REPO" "$CHAIN_WORKTREE" feature/chain "$ISSUE_ONE" feature/chain-issue-one local-clone
git -C "$ISSUE_ONE" config user.name "Fixture"
git -C "$ISSUE_ONE" config user.email "fixture@example.com"
printf 'from first issue\n' > "$ISSUE_ONE/first.txt"
git -C "$ISSUE_ONE" add first.txt
git -C "$ISSUE_ONE" commit -q -m "Closes #580 first leaf"
chain_git_integrate_issue_workspace "$REPO" "$CHAIN_WORKTREE" feature/chain "$ISSUE_ONE" feature/chain-issue-one local-clone

chain_git_prepare_issue_workspace "$REPO" "$CHAIN_WORKTREE" feature/chain "$ISSUE_TWO" feature/chain-issue-two local-clone
[ -f "$ISSUE_TWO/first.txt" ] || fail "second local-clone issue did not inherit first issue commit"

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
  "title": "Sequential fixture $issue",
  "body": "Exercise sequential chain integration.",
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

manifest="$TMPROOT/chain.yaml"
cat > "$manifest" <<'YAML'
schema_version: 1
chains:
  - name: sequential-fixture
    base: main
    branch: feature/sequential-fixture
    host: codex
    phase_review: off
    issues: [580, 581]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --dry-run > "$TMPROOT/out" 2>&1

awk '
  /studio-chain-runner: issue #580 ->/ { issue_one=NR }
  /DRY-RUN git -C .*merge --ff-only FETCH_HEAD/ && issue_one && !merge_one { merge_one=NR }
  /studio-chain-runner: issue #581 ->/ { issue_two=NR }
  END { exit !(issue_one && merge_one && issue_two && issue_one < merge_one && merge_one < issue_two) }
' "$TMPROOT/out" || {
  cat "$TMPROOT/out" >&2
  fail "dry-run did not integrate first issue before launching second issue"
}

awk '
  /if \[ "\$issue_status" = "completed" \]/ { completed_block=1 }
  /integrate_issue_result "\$name" "\$branch" "\$chain_worktree" "\$issue"/ && completed_block { integrated=1 }
  /continue/ && completed_block && integrated { ok=1 }
  END { exit !ok }
' "$ROOT/scripts/studio-chain-runner.sh" || fail "resume completed-issue path does not integrate before continuing"

printf 'PASS: chain sequential integration\n'
