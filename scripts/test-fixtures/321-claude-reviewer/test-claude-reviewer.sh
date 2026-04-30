#!/usr/bin/env bash
# Verifies claude-reviewer is eligible for headless PR review and normal
# claude-code remains ineligible.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t claude-reviewer.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'claude fixture help\n'; exit 0 ;;
esac
case " $* " in
  *"stdout-fail"*) printf 'fixture startup stdout\n'; exit 17 ;;
esac

case " $* " in
  *" -p "*|*" --print "*) ;;
  *) printf 'claude reviewer was not headless\n' >&2; exit 3 ;;
esac
case " $* " in
  *" --permission-mode dontAsk "*) ;;
  *) printf 'claude reviewer can still prompt\n' >&2; exit 4 ;;
esac
case " $* " in
  *" --setting-sources project "*) ;;
  *) printf 'claude reviewer inherited user/local settings\n' >&2; exit 5 ;;
esac
case " $* " in
  *" --disable-slash-commands "*) ;;
  *) printf 'claude reviewer inherited slash commands\n' >&2; exit 6 ;;
esac
case " $* " in
  *" --no-session-persistence "*) ;;
  *) printf 'claude reviewer persisted session state\n' >&2; exit 7 ;;
esac
case " $* " in
  *" --strict-mcp-config "*) ;;
  *) printf 'claude reviewer inherited MCP config\n' >&2; exit 8 ;;
esac
case " $* " in
  *" --mcp-config .claude-reviewer/mcp-empty.json "*) ;;
  *) printf 'claude reviewer did not use isolated MCP config file\n' >&2; exit 13 ;;
esac
[ -f ".claude-reviewer/mcp-empty.json" ] || { printf 'claude reviewer launched outside repo root\n' >&2; exit 14; }
grep -q '"mcpServers"[[:space:]]*:[[:space:]]*{}' ".claude-reviewer/mcp-empty.json" \
  || { printf 'claude reviewer MCP config is not empty\n' >&2; exit 15; }
case " $* " in
  *" --tools=Read,Grep,Glob "*) ;;
  *) printf 'claude reviewer did not use read-only tools\n' >&2; exit 9 ;;
esac

[ -n "${REVIEW_PAYLOAD:-}" ] && [ -f "$REVIEW_PAYLOAD" ] || exit 10
[ ! -f "$HOME/.config/gh/hosts.yml" ] || { printf 'reviewer inherited caller HOME\n' >&2; exit 11; }
case "${GH_TOKEN:-}${GITHUB_TOKEN:-}${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}" in
  "") ;;
  *) printf 'secret leaked into reviewer env\n' >&2; exit 12 ;;
esac

printf 'claude review summary\n'
printf 'STUDIO_REVIEW_VERDICT=approved\n'
SH
chmod +x "$BIN/claude"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -u

case "$1 $2" in
  "pr view")
    case " $* " in
      *" --jq .number "*|*" --jq "*) printf '123\n' ;;
      *" stdout-fail "*) printf '{"number":124,"title":"Fixture PR","url":"https://github.com/owner/repo/pull/stdout-fail","baseRefName":"main","headRefName":"feature","headRefOid":"abc124","author":{"login":"author"},"commits":[{"oid":"abc124"}]}\n' ;;
      *) printf '{"number":123,"title":"Fixture PR","url":"https://github.com/owner/repo/pull/123","baseRefName":"main","headRefName":"feature","headRefOid":"abc123","author":{"login":"author"},"commits":[{"oid":"abc123"}]}\n' ;;
    esac
    ;;
  "pr diff")
    printf 'diff --git a/file b/file\n+change\n'
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN/gh"

cat > "$BIN/autopilot" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${AUTOPILOT_LOG:?}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary-file) summary="${2:?}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${summary:-}" ] && grep -q 'STUDIO_REVIEW_VERDICT=approved' "$summary"
SH
chmod +x "$BIN/autopilot"

export PATH="$BIN:$PATH"
export PR_HEADLESS_REVIEW_AUTOPILOT="$BIN/autopilot"
export AUTOPILOT_LOG="$TMPROOT/autopilot.log"
export GH_TOKEN="must-not-leak"
export GITHUB_TOKEN="must-not-leak"
export OPENAI_API_KEY="must-not-leak"
export ANTHROPIC_API_KEY="must-not-leak"
export HOME="$TMPROOT/caller-home"
mkdir -p "$HOME/.config/gh"
printf 'github.com: token\n' > "$HOME/.config/gh/hosts.yml"

failures=0
assert() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

eligibility="$TMPROOT/eligibility.out"
bash "$ROOT/scripts/pr-reviewer-eligibility.sh" claude-reviewer >"$eligibility" 2>"$eligibility.err"
rc=$?
assert "claude-reviewer is eligible" "[ '$rc' -eq 0 ]"
assert "eligibility reports claude reviewer" "grep -q 'HOST=claude-reviewer' '$eligibility'"
assert "eligibility reports reviewer manifest" "grep -q 'MANIFEST=.claude-reviewer/capabilities.yaml' '$eligibility'"
global_skill_dir=$(yq -r '."claude-reviewer".global_skill_dir' "$ROOT/hosts/registry.yaml")
project_skill_dir=$(yq -r '."claude-reviewer".project_skill_dir' "$ROOT/hosts/registry.yaml")
assert "claude-reviewer has isolated global skill dir" "[ '$global_skill_dir' = '~/.claude-reviewer/skills' ]"
assert "claude-reviewer has isolated project skill dir" "[ '$project_skill_dir' = '.claude-reviewer/skills' ]"

normal="$TMPROOT/normal.out"
if bash "$ROOT/scripts/pr-reviewer-eligibility.sh" claude-code >"$normal" 2>"$normal.err"; then
  printf 'not ok - normal claude-code unexpectedly eligible\n' >&2
  failures=$((failures + 1))
else
  assert "normal claude-code fails secret floor" "grep -q 'REASON=secret_scope_floor_unmet' '$normal'"
fi

MINI_REPO="$TMPROOT/mini-repo"
mkdir -p "$MINI_REPO/scripts" "$MINI_REPO/hosts" "$MINI_REPO/.bad-claude-reviewer"
cp "$ROOT/scripts/pr-reviewer-eligibility.sh" "$MINI_REPO/scripts/pr-reviewer-eligibility.sh"
cp "$ROOT/scripts/lib-paths.sh" "$MINI_REPO/scripts/lib-paths.sh"
cat > "$MINI_REPO/hosts/registry.yaml" <<'YAML'
bad-claude-reviewer:
  display_name: "Bad Claude Reviewer"
  detect_binary: claude
  capabilities_path: ".bad-claude-reviewer/capabilities.yaml"
YAML
cat > "$MINI_REPO/.bad-claude-reviewer/capabilities.yaml" <<'YAML'
supports_hooks: false
spawn_command: "claude -p --permission-mode dontAsk --setting-sources project --disable-slash-commands --no-session-persistence --strict-mcp-config --mcp-config .claude-reviewer/mcp-empty.json --tools=Read,Grep,Glob,Bash"
block_for_event_strategy: tail
tool_dialect: claude
sandbox_profile: read-only
secret_scope: none
reviewer_profile: true
YAML

bad_tools="$TMPROOT/bad-tools.out"
if bash "$MINI_REPO/scripts/pr-reviewer-eligibility.sh" bad-claude-reviewer >"$bad_tools" 2>"$bad_tools.err"; then
  printf 'not ok - claude reviewer accepted appended Bash tool\n' >&2
  failures=$((failures + 1))
else
  assert "claude reviewer rejects appended write tool" "grep -q 'REASON=write_tool_floor_unmet' '$bad_tools'"
fi

out="$TMPROOT/out.txt"
bash "$ROOT/scripts/pr-headless-review.sh" 123 --review-host claude-reviewer --method auto >"$out" 2>"$out.err"
rc=$?

assert "headless claude review exits zero" "[ '$rc' -eq 0 ]"
assert "review host reported" "grep -q 'PR_REVIEW_HOST=claude-reviewer' '$out'"
assert "verdict parsed" "grep -q 'PR_REVIEW_VERDICT=approved' '$out'"
assert "autopilot receives review host" "grep -q -- '--review-host claude-reviewer' '$AUTOPILOT_LOG'"

fail_out="$TMPROOT/fail-out.txt"
if bash "$ROOT/scripts/pr-headless-review.sh" stdout-fail --review-host claude-reviewer --method auto >"$fail_out" 2>"$fail_out.err"; then
  printf 'not ok - claude reviewer stdout failure unexpectedly succeeded\n' >&2
  failures=$((failures + 1))
else
  assert "startup stdout failure labels stdout" "grep -q 'reviewer stdout' '$fail_out.err'"
  assert "startup stdout failure includes detail" "grep -q 'fixture startup stdout' '$fail_out.err'"
fi

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s)\n' "$failures" >&2
  sed -n '1,120p' "$eligibility.err" >&2 || true
  sed -n '1,120p' "$out.err" >&2 || true
  exit 1
fi

printf 'PASS: claude reviewer eligibility and headless review\n'
