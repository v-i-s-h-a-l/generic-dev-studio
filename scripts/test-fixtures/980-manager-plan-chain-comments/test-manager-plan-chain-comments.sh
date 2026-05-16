#!/usr/bin/env bash
# Fixture for comment-aware manager plan-chain intake (#983).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/manager-plan-chain.sh"
TMPROOT=$(mktemp -d -t manager-plan-chain-comments.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
if ! command -v yq >/dev/null 2>&1; then
  printf 'SKIP: yq required for manager plan-chain fixture\n'
  exit 0
fi

BIN="$TMPROOT/bin"
mkdir -p "$BIN" "$TMPROOT/home"
GH_LOG="$TMPROOT/gh.log"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

printf '%s\n' "$*" >> "${GH_LOG:?}"

api_path=""
for arg in "$@"; do
  case "$arg" in
    /repos/*|repos/*) api_path="$arg" ;;
  esac
done

issue_json() {
  issue="$1"
  cat <<JSON
{
  "id": $((100000 + issue)),
  "number": $issue,
  "title": "Comment-aware issue $issue",
  "body": "Input source: issue brief.\\nOutput artifact format: YAML work-chain manifest.\\nVerification evidence: fixture test.\\n\\nScope:\\n- Write comment-aware intake for issue $issue to `scripts/manager-plan-chain.sh`.\\n\\nOut of scope:\\n- Worker execution.\\n\\nAcceptance:\\n- The plan-chain artifact records packet and sidecar paths.",
  "url": "https://api.github.com/repos/example/project/issues/$issue",
  "html_url": "https://github.com/example/project/issues/$issue",
  "state": "OPEN",
  "created_at": "2026-05-16T22:00:00Z",
  "updated_at": "2026-05-16T22:01:00Z",
  "user": {"login": "fixture-human", "type": "User"}
}
JSON
}

comments_json() {
  issue="$1"
  cat <<JSON
[
  [
    {
      "id": $((200000 + issue)),
      "html_url": "https://github.com/example/project/issues/$issue#issuecomment-$((200000 + issue))",
      "created_at": "2026-05-16T22:02:00Z",
      "updated_at": "2026-05-16T22:02:00Z",
      "user": {"login": "fixture-human", "type": "User"},
      "body": "Decision: include comments only through the public-safe packet builder."
    },
    {
      "id": $((210000 + issue)),
      "html_url": "https://github.com/example/project/issues/$issue#issuecomment-$((210000 + issue))",
      "created_at": "2026-05-16T22:03:00Z",
      "updated_at": "2026-05-16T22:03:00Z",
      "user": {"login": "fixture-human", "type": "User"},
      "body": "Acceptance criteria: artifacts must record packet and sidecar paths."
    }
  ]
]
JSON
}

if [ "$1" = "api" ]; then
  case "$api_path" in
    repos/example/project/issues/*/comments*|/repos/example/project/issues/*/comments*)
      issue=${api_path#*issues/}
      issue=${issue%%/*}
      comments_json "$issue"
      exit 0
      ;;
    repos/example/project/issues/*|/repos/example/project/issues/*)
      issue=${api_path##*/}
      issue_json "$issue"
      exit 0
      ;;
  esac
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

PATH="$BIN:$PATH" \
HOME="$TMPROOT/home" \
GH_LOG="$GH_LOG" \
STUDIO_MANAGER_PLAN_CHAIN_PROJECT=generic-dev-studio \
STUDIO_MANAGER_PLAN_CHAIN_RUN_ID=single-comments \
  "$RUN" --issue 980 --include-comments --repo example/project --chain comments-single --allow-missing-details --dry-run --no-project-fields >"$TMPROOT/single.out" 2>"$TMPROOT/single.err"

SINGLE_ROOT="$TMPROOT/home/.dev-studio/generic-dev-studio/plan-chains/single-comments"
SINGLE_RESULT="$SINGLE_ROOT/result.json"
SINGLE_PLANNER="$SINGLE_ROOT/planner-output.json"

jq -e '
  (.status == "dry_run" or .status == "needs_context")
  and .source_context.comments_included == true
  and (.source_context.packet_path | endswith("/issue-context-packet/packet.md"))
  and (.source_context.comment_sidecar_path | endswith("/issue-context-packet/packet.json"))
' "$SINGLE_RESULT" >/dev/null || {
  cat "$TMPROOT/single.out" >&2
  cat "$TMPROOT/single.err" >&2
  fail "single issue result did not record comment packet paths"
}

jq -e '
  .payload.source_context.comments_included == true
  and any(.evidence_refs[]; endswith("/issue-context-packet/packet.md"))
  and any(.evidence_refs[]; endswith("/issue-context-packet/packet.json"))
' "$SINGLE_PLANNER" >/dev/null || fail "planner artifact did not record packet evidence"

grep -q '## Issue Bodies' "$SINGLE_ROOT/issue-context-packet/packet.md" \
  || fail "packet markdown did not include issue body section"
grep -q 'Decision: include comments only through the public-safe packet builder' "$SINGLE_ROOT/issue-context-packet/packet.md" \
  || fail "packet markdown did not include classified comment signal"
grep -q 'repos/example/project/issues/980/comments' "$GH_LOG" \
  || fail "single issue comments were not fetched through issue-context-packet"

: > "$GH_LOG"
PATH="$BIN:$PATH" \
HOME="$TMPROOT/home" \
GH_LOG="$GH_LOG" \
STUDIO_MANAGER_PLAN_CHAIN_PROJECT=generic-dev-studio \
STUDIO_MANAGER_PLAN_CHAIN_RUN_ID=cluster-comments \
  "$RUN" --issue-set 980,#981 --include-comments --repo example/project --chain comments-cluster --allow-missing-details --dry-run --no-project-fields >"$TMPROOT/cluster.out" 2>"$TMPROOT/cluster.err"

CLUSTER_ROOT="$TMPROOT/home/.dev-studio/generic-dev-studio/plan-chains/cluster-comments"
CLUSTER_RESULT="$CLUSTER_ROOT/result.json"
CLUSTER_PACKET="$CLUSTER_ROOT/issue-context-packet/packet.json"

jq -e '
  (.status == "dry_run" or .status == "needs_context")
  and .source_context.comments_included == true
  and .source_context.mode == "issue-context-packet"
' "$CLUSTER_RESULT" >/dev/null || {
  cat "$TMPROOT/cluster.out" >&2
  cat "$TMPROOT/cluster.err" >&2
  fail "cluster result did not record issue-context-packet mode"
}

jq -e '
  .source_issue.number == 980
  and (.included_comment_range.total_count == 4)
  and (.comments | length == 4)
' "$CLUSTER_PACKET" >/dev/null || {
  jq . "$CLUSTER_PACKET" >&2
  fail "cluster packet did not preserve both source issues"
}

jq -e 'map(.number) | sort == [980, 981]' "$CLUSTER_ROOT/issue-context-packet/raw/issue.json" >/dev/null \
  || fail "cluster raw issue archive did not preserve both source issues"

grep -q 'repos/example/project/issues/980/comments' "$GH_LOG" \
  || fail "cluster did not fetch issue 980 comments"
grep -q 'repos/example/project/issues/981/comments' "$GH_LOG" \
  || fail "cluster did not fetch issue 981 comments"

printf 'PASS: manager plan-chain comment-aware intake\n'
