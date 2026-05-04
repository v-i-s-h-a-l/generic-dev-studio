#!/usr/bin/env bash
# Verifies sandboxed chain issues use git metadata inside the issue root.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-git-metadata.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

. "$ROOT/scripts/lib-chain-git.sh"

REPO="$TMPROOT/repo"
CHAIN_WORKTREE="$TMPROOT/chain"
ISSUE_WORKTREE="$TMPROOT/issue"

git init -q "$REPO"
git -C "$REPO" config user.name "Fixture"
git -C "$REPO" config user.email "fixture@example.com"
printf 'base\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m "base"
git -C "$REPO" branch -M main
git -C "$REPO" worktree add -q -B feature/chain "$CHAIN_WORKTREE" main

chain_git_prepare_issue_workspace "$REPO" "$CHAIN_WORKTREE" feature/chain "$ISSUE_WORKTREE" feature/chain-issue-571 local-clone

[ -d "$ISSUE_WORKTREE/.git" ] || {
  printf 'local-clone strategy did not create issue-local .git directory\n' >&2
  exit 1
}

[ ! -f "$ISSUE_WORKTREE/.git/objects/info/alternates" ] || {
  printf 'local-clone strategy left object alternates outside the issue root\n' >&2
  exit 1
}

git -C "$ISSUE_WORKTREE" config user.name "Fixture"
git -C "$ISSUE_WORKTREE" config user.email "fixture@example.com"
printf 'change\n' > "$ISSUE_WORKTREE/change.txt"
git -C "$ISSUE_WORKTREE" add change.txt
git -C "$ISSUE_WORKTREE" commit -q -m "Closes #571"

chain_git_integrate_issue_workspace "$REPO" "$CHAIN_WORKTREE" feature/chain "$ISSUE_WORKTREE" feature/chain-issue-571 local-clone

[ ! -e "$ISSUE_WORKTREE" ] || {
  printf 'local-clone integration did not remove issue worktree\n' >&2
  exit 1
}

git -C "$CHAIN_WORKTREE" show --name-only --oneline HEAD | grep -q 'change.txt' || {
  printf 'local-clone issue commit was not integrated into chain worktree\n' >&2
  exit 1
}

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
  "title": "Git metadata fixture $issue",
  "body": "Exercise git metadata strategy.",
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
  - name: git-metadata-fixture
    base: main
    branch: feature/git-metadata-fixture
    host: codex
    issues: [571]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --dry-run > "$TMPROOT/out" 2>&1

grep -q 'Git metadata strategy: `local-clone`' "$TMPROOT/out" || {
  printf 'dry-run plan did not show local-clone strategy\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}

grep -q 'DRY-RUN git clone --no-local' "$TMPROOT/out" || {
  printf 'dry-run command trace did not use local clone for codex\n' >&2
  cat "$TMPROOT/out" >&2
  exit 1
}

grep -n 'run_issue_job' "$ROOT/scripts/studio-chain-runner.sh" | grep -q 'git_metadata_strategy' || {
  printf 'runner does not pass git metadata strategy into issue jobs\n' >&2
  exit 1
}

awk '
  /run_issue_job/ { seen_run=1 }
  /abort_run "\$result_reason"/ && seen_run { seen_abort=1 }
  /for \(\(i = 0; i < issue_count; i\+\+\)\)/ && seen_abort { seen_merge_loop=1 }
  END { exit !(seen_run && seen_abort && seen_merge_loop) }
' "$ROOT/scripts/studio-chain-runner.sh" || {
  printf 'runner does not halt failed issue jobs before the integration loop\n' >&2
  exit 1
}

printf 'PASS: chain git metadata strategy\n'
