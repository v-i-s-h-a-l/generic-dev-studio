#!/usr/bin/env bash
# Regression fixture: manager plan-chain reviews planner output before chain creation.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/manager-plan-chain.sh"
MANAGER="$ROOT/scripts/manager-work-chain.sh"
TMPROOT=$(mktemp -d -t manager-plan-chain-758.XXXXXX)
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

[ -x "$RUN" ] || fail "scripts/manager-plan-chain.sh is not executable"

BIN="$TMPROOT/bin"
mkdir -p "$BIN" "$TMPROOT/home" "$TMPROOT/claude-reviewer"

GH_LOG="$TMPROOT/gh.log"
ISSUE_COUNTER="$TMPROOT/issue-counter"
printf '9100\n' > "$ISSUE_COUNTER"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

printf '%s\n' "$*" >> "${GH_LOG:?}"

api_path=""
for arg in "$@"; do
  case "$arg" in
    /repos/*) api_path="$arg" ;;
  esac
done

if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  n=$(cat "${ISSUE_COUNTER:?}")
  n=$((n + 1))
  printf '%s\n' "$n" > "$ISSUE_COUNTER"
  printf 'https://github.com/example/project/issues/%s\n' "$n"
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "Issue $issue fixture",
  "body": "Input source: issue brief.\\nOutput artifact format: YAML work-chain manifest.\\nVerification evidence: fixture test.\\n\\nScope:\\n- Create reviewed plan-chain output.\\n\\nOut of scope:\\n- Worker execution.\\n\\nAcceptance:\\n- The command prints the work-chain path.",
  "url": "https://github.com/example/project/issues/$issue",
  "state": "OPEN"
}
JSON
  exit 0
fi

if [ "$1" = "api" ]; then
  case "$api_path" in
    /repos/example/project/issues/*/sub_issues)
      case " $* " in
        *" -X POST "*) printf '{"linked":true}\n' ;;
        *) printf '[]\n' ;;
      esac
      exit 0
      ;;
    /repos/example/project/issues/*)
      issue=${api_path##*/}
      cat <<JSON
{"id": $((100000 + issue)), "number": $issue, "url": "https://api.github.com/repos/example/project/issues/$issue", "html_url": "https://github.com/example/project/issues/$issue"}
JSON
      exit 0
      ;;
  esac
fi

if [ "$1" = "project" ] && [ "$2" = "view" ]; then
  printf '{"id":"PVT_fixture","number":1,"title":"Fixture Project"}\n'
  exit 0
fi

if [ "$1" = "project" ] && [ "$2" = "field-list" ]; then
  cat <<'JSON'
{
  "fields": [
    {"id":"FIELD_STATUS","name":"Status","options":[{"id":"OPT_TODO","name":"Todo"},{"id":"OPT_IN_PROGRESS","name":"In Progress"},{"id":"OPT_DONE","name":"Done"}]},
    {"id":"FIELD_TRACK","name":"Track","options":[{"id":"OPT_D","name":"D chain mode"},{"id":"OPT_BACKLOG","name":"backlog"}]},
    {"id":"FIELD_PHASE","name":"Phase","options":[{"id":"OPT_D_PHASE","name":"D"}]},
    {"id":"FIELD_SIZE","name":"Size","options":[{"id":"OPT_S","name":"S"},{"id":"OPT_M","name":"M"}]},
    {"id":"FIELD_REVIEW","name":"Sibling host reviewed","options":[{"id":"OPT_PLAN_CLEAN","name":"Plan clean"},{"id":"OPT_NEEDS_REVIEW","name":"Needs review"}]}
  ]
}
JSON
  exit 0
fi

if [ "$1" = "project" ] && [ "$2" = "item-add" ]; then
  url=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--url" ]; then
      url="$arg"
    fi
    prev="$arg"
  done
  number=${url##*/}
  printf '{"id":"PVTI_%s"}\n' "$number"
  exit 0
fi

if [ "$1" = "project" ] && [ "$2" = "item-edit" ]; then
  printf '{"ok":true}\n'
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

cat > "$BIN/work-chain-exec" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'work-chain-exec %s\n' "$*"
case " $* " in
  *" --attended "*) printf 'unexpected attended execution\n' >&2; exit 12 ;;
esac
test -f "$1" || { printf 'missing generated manifest: %s\n' "$1" >&2; exit 13; }
printf 'chain executed\n'
SH
chmod +x "$BIN/work-chain-exec"

cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'claude fixture help\n'; exit 0 ;;
esac
[ -n "${REVIEW_PAYLOAD:-}" ] && [ -f "$REVIEW_PAYLOAD" ] || { printf 'missing review payload\n' >&2; exit 10; }
case "${GH_TOKEN:-}${GITHUB_TOKEN:-}${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}" in
  "") ;;
  *) printf 'secret leaked into reviewer env\n' >&2; exit 11 ;;
esac
case " $* " in
  *"STUDIO_REVIEW_VERDICT"*) printf 'STUDIO_REVIEW_VERDICT=approved\n'; exit 0 ;;
esac
grep -q 'Manager Plan-Chain Phase Plan' "$REVIEW_PAYLOAD" || { printf 'wrong review payload\n' >&2; exit 12; }
printf 'No fatal blockers. Planner output can be ingested.\nPHASE_REVIEW_VERDICT=clean\n'
SH
chmod +x "$BIN/claude"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'codex fixture help\n'; exit 0 ;;
esac
case " $* " in
  *"STUDIO_REVIEW_VERDICT"*) printf 'STUDIO_REVIEW_VERDICT=approved\n'; exit 0 ;;
esac
printf 'PHASE_REVIEW_VERDICT=clean\n'
SH
chmod +x "$BIN/codex"

SOURCE="$TMPROOT/source.md"
cat > "$SOURCE" <<'EOF'
Input source: issue brief.
Output artifact format: YAML work-chain manifest.
Verification evidence: fixture test.

Scope:
- Create the reusable planner artifact.
- Write implementation to `scripts/manager-plan-chain.sh` after R001.

Out of scope:
- Worker execution.

Acceptance:
- The clean-session command is printed.

Cross-links:
- Track: `D chain mode`
EOF

PATH="$BIN:$PATH" \
HOME="$TMPROOT/home" \
GH_LOG="$GH_LOG" \
ISSUE_COUNTER="$ISSUE_COUNTER" \
CLAUDE_REVIEWER_HOME="$TMPROOT/claude-reviewer" \
CLAUDE_REVIEWER_CONFIG_DIR="$TMPROOT/claude-reviewer/.claude-reviewer" \
STUDIO_PARENT_HOST=codex \
STUDIO_MANAGER_PLAN_CHAIN_PROJECT=generic-dev-studio \
STUDIO_MANAGER_PLAN_CHAIN_RUN_ID=happy \
  "$RUN" --source-file "$SOURCE" --repo example/project --chain reviewed-chain >"$TMPROOT/happy.out" 2>"$TMPROOT/happy.err"

grep -q 'Status: `ready`' "$TMPROOT/happy.out" || {
  cat "$TMPROOT/happy.out" >&2
  cat "$TMPROOT/happy.err" >&2
  fail "happy path did not return ready"
}
grep -q 'Review artifact: `' "$TMPROOT/happy.out" || fail "happy path omitted review artifact"
grep -q 'Work-chain: `' "$TMPROOT/happy.out" || fail "happy path omitted work-chain path"
grep -q 'Clean-session command: `/dev-studio manager work-chain ' "$TMPROOT/happy.out" || fail "happy path omitted clean command"
grep -q '^issue create --repo example/project ' "$GH_LOG" || {
  cat "$GH_LOG" >&2
  fail "happy path did not create durable issues through studio-gh"
}

RESULT="$TMPROOT/home/.dev-studio/generic-dev-studio/plan-chains/happy/result.json"
MANIFEST="$TMPROOT/home/.dev-studio/generic-dev-studio/plan-chains/happy/work-chain.yaml"
REVIEW="$TMPROOT/home/.dev-studio/generic-dev-studio/plan-chains/happy/plan-review.md"

jq -e '
  .status == "ready" and
  (.created_issues | length) >= 2 and
  (.parent_issue.number == 9101) and
  ([.created_issues[].sub_issue_linked] | all) and
  (.project_fields.items | length) == ((.created_issues | length) + 1) and
  .automation_mode == "unattended" and
  (.blocked_decisions | length) == 0 and
  (.clean_session_command | test("^/dev-studio manager work-chain ")) and
  (.execution.requested == false)
' "$RESULT" >/dev/null || fail "result JSON did not capture ready state"

yq -e '
  .schema_version == 1 and
  .issue_repo == "example/project" and
  .chains[0].name == "reviewed-chain" and
  .chains[0].phase_review == "required" and
  (.chains[0].issues | length) >= 2
' "$MANIFEST" >/dev/null || fail "generated work-chain manifest is not runnable shape"

grep -q 'PHASE_REVIEW_VERDICT=clean' "$REVIEW" || fail "phase review artifact missing clean verdict"
grep -q '^project item-add 1 --owner v-i-s-h-a-l --url https://github.com/example/project/issues/9101 ' "$GH_LOG" \
  || fail "parent issue was not added to the Project"
grep -q '^api .* /repos/example/project/issues/9101/sub_issues$' "$GH_LOG" \
  || fail "native sub-issue API was not read before linking"
grep -q 'sub_issue_id=109102' "$GH_LOG" \
  || fail "worker issue was not linked as a native sub-issue"
grep -q '^project item-edit ' "$GH_LOG" \
  || fail "Project single-select fields were not populated"

: > "$GH_LOG"
ROUGH="$TMPROOT/rough.md"
cat > "$ROUGH" <<'EOF'
Maybe make this workflow nicer someday?
EOF

PATH="$BIN:$PATH" \
HOME="$TMPROOT/home" \
GH_LOG="$GH_LOG" \
ISSUE_COUNTER="$ISSUE_COUNTER" \
STUDIO_MANAGER_PLAN_CHAIN_PROJECT=generic-dev-studio \
STUDIO_MANAGER_PLAN_CHAIN_RUN_ID=blocked \
  "$RUN" --source-file "$ROUGH" --repo example/project --chain rough-chain >"$TMPROOT/blocked.out" 2>"$TMPROOT/blocked.err"

grep -q 'Status: `needs_context`' "$TMPROOT/blocked.out" || {
  cat "$TMPROOT/blocked.out" >&2
  cat "$TMPROOT/blocked.err" >&2
  fail "rough source did not return needs_context"
}
if grep -q '^issue create ' "$GH_LOG"; then
  cat "$GH_LOG" >&2
  fail "needs_context path created issues"
fi
[ ! -f "$TMPROOT/home/.dev-studio/generic-dev-studio/plan-chains/blocked/work-chain.yaml" ] \
  || fail "needs_context path created a work-chain manifest"

TASK_GRAPH="$TMPROOT/home/.dev-studio/generic-dev-studio/plan-chains/happy/task-graph.json"
PATH="$BIN:$PATH" \
HOME="$TMPROOT/home" \
GH_LOG="$GH_LOG" \
ISSUE_COUNTER="$ISSUE_COUNTER" \
CLAUDE_REVIEWER_HOME="$TMPROOT/claude-reviewer" \
CLAUDE_REVIEWER_CONFIG_DIR="$TMPROOT/claude-reviewer/.claude-reviewer" \
STUDIO_PARENT_HOST=codex \
STUDIO_MANAGER_PLAN_CHAIN_PROJECT=generic-dev-studio \
STUDIO_MANAGER_PLAN_CHAIN_RUN_ID=from-plan \
STUDIO_MANAGER_PLAN_CHAIN_EXECUTOR="$BIN/work-chain-exec" \
  "$MANAGER" --from-plan "$TASK_GRAPH" --repo example/project --chain from-plan-chain >"$TMPROOT/from-plan.out" 2>"$TMPROOT/from-plan.err"

grep -q 'Status: `executed`' "$TMPROOT/from-plan.out" || {
  cat "$TMPROOT/from-plan.out" >&2
  cat "$TMPROOT/from-plan.err" >&2
  fail "manager work-chain --from-plan did not execute the generated chain"
}
grep -q 'Execution: `completed`' "$TMPROOT/from-plan.out" \
  || fail "from-plan execution status was not reported"

printf 'PASS: manager plan-chain orchestration\n'
