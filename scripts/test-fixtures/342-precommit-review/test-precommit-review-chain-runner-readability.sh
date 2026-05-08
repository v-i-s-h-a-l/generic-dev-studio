#!/usr/bin/env bash
# Verifies chain-runner issue worktrees hand pre-commit reviewer payloads through
# the durable Studio runtime root instead of the temp worktree.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t precommit-review-chain.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
REPO="$TMPROOT/studio-chain-runner/run-123/chain-issue-634"
DURABLE_HOME="$TMPROOT/durable-home"
STUDIO_ROOT="$DURABLE_HOME/.dev-studio"
EXPECTED_PAYLOAD_PARENT="$STUDIO_ROOT/generic-dev-studio/.runtime/reviewer-payloads/pre-commit"
PAYLOAD_PATH_RECORD="$TMPROOT/payload-path.txt"
mkdir -p "$BIN" "$REPO/.studio" "$DURABLE_HOME" "$TMPROOT/session-tmp"

cat > "$REPO/.studio/chain-task-start.json" <<'JSON'
{
  "source_issue": {
    "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/634"
  }
}
JSON

cat > "$BIN/yq" <<'SH'
#!/usr/bin/env bash
expr="$2"
case "$expr" in
  *detect_binary*) printf 'claude\n' ;;
  *capabilities_path*) printf '.claude-reviewer/capabilities.yaml\n' ;;
  *) printf 'unexpected yq expression: %s\n' "$expr" >&2; exit 2 ;;
esac
SH
chmod +x "$BIN/yq"

expected_payload_parent_q=$(printf '%q' "$EXPECTED_PAYLOAD_PARENT")
chain_worktree_q=$(printf '%q' "$REPO")
payload_path_record_q=$(printf '%q' "$PAYLOAD_PATH_RECORD")
{
printf '#!/usr/bin/env bash\n'
printf 'EXPECTED_PAYLOAD_PARENT=%s\n' "$expected_payload_parent_q"
printf 'CHAIN_WORKTREE=%s\n' "$chain_worktree_q"
printf 'PAYLOAD_PATH_RECORD=%s\n' "$payload_path_record_q"
cat <<'SH'
case " $* " in
  *" --help "*) printf 'claude fixture help\n'; exit 0 ;;
  *"smoke test"*) printf 'STUDIO_REVIEW_VERDICT=approved\n'; exit 0 ;;
esac

[ -n "${REVIEW_PAYLOAD:-}" ] && [ -f "$REVIEW_PAYLOAD" ] || { printf 'missing payload\n' >&2; exit 3; }
case "$REVIEW_PAYLOAD" in
  "$EXPECTED_PAYLOAD_PARENT"/run.*/review-payload.md) ;;
  *) printf 'payload not under durable runtime root: %s\n' "$REVIEW_PAYLOAD" >&2; exit 4 ;;
esac
case "$REVIEW_PAYLOAD" in
  "$CHAIN_WORKTREE"/*) printf 'payload stayed in chain worktree: %s\n' "$REVIEW_PAYLOAD" >&2; exit 5 ;;
esac
case " $* " in
  *" --add-dir=$EXPECTED_PAYLOAD_PARENT"/run.*) ;;
  *" --add-dir $EXPECTED_PAYLOAD_PARENT"/run.*) ;;
  *) printf 'missing add-dir for durable payload root\n' >&2; exit 6 ;;
esac
grep -q 'Staged diff:' "$REVIEW_PAYLOAD" || exit 7
printf '%s\n' "$REVIEW_PAYLOAD" > "$PAYLOAD_PATH_RECORD"
printf 'STUDIO_REVIEW_VERDICT=approved\n'
SH
} > "$BIN/claude"
chmod +x "$BIN/claude"

export PATH="$BIN:$PATH"
export HOME="$TMPROOT/caller-home"
export TMPDIR="$TMPROOT/session-tmp"
export STUDIO_CONTEXT_STUDIO_HOME="$STUDIO_ROOT"
export CLAUDE_REVIEWER_HOME="$TMPROOT/claude-reviewer-home"
export CLAUDE_REVIEWER_CONFIG_DIR="$TMPROOT/claude-reviewer-config"
export STUDIO_REVIEWER_SMOKE_TIMEOUT_SEC=0
mkdir -p "$HOME" "$CLAUDE_REVIEWER_HOME" "$CLAUDE_REVIEWER_CONFIG_DIR"

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
printf 'one\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm initial
printf 'two\n' >> "$REPO/file.txt"
git -C "$REPO" add file.txt

out="$TMPROOT/out.txt"
err="$TMPROOT/err.txt"
if ! (cd "$REPO" && bash "$ROOT/scripts/pre-commit-review.sh" --review-host claude-reviewer >"$out" 2>"$err"); then
  printf 'FAIL: pre-commit review rejected durable payload handoff\n' >&2
  sed -n '1,120p' "$err" >&2 || true
  exit 1
fi

grep -q 'PRECOMMIT_REVIEW_HOST=claude-reviewer' "$out" || {
  printf 'FAIL: review host not reported\n' >&2
  exit 1
}
grep -q 'PRECOMMIT_REVIEW_PAYLOAD_STORAGE=studio-runtime' "$out" || {
  printf 'FAIL: payload storage not reported\n' >&2
  exit 1
}
[ -s "$PAYLOAD_PATH_RECORD" ] || {
  printf 'FAIL: fixture did not observe review payload\n' >&2
  exit 1
}

event_log=$(find "$HOME/.dev-studio" -type f -path '*/events/*.jsonl' | head -1)
[ -n "$event_log" ] || { printf 'FAIL: missing event log\n' >&2; exit 1; }
jq -e 'select(.event == "precommit_review_passed" and .data.payload_storage == "studio-runtime" and .data.status == "passed")' "$event_log" >/dev/null \
  || { printf 'FAIL: passed event did not record payload storage/status\n' >&2; exit 1; }

printf 'PASS: pre-commit review chain-runner payload handoff\n'
