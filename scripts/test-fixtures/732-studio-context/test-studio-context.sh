#!/usr/bin/env bash
# Verifies the Studio context resolver keeps durable data roots separate from
# host/auth homes across login-home and synthetic-home launches.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-context.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
LOGIN_HOME="$TMPROOT/login-home"
SYNTH_HOME="$TMPROOT/.codex-homes/personal"
CODEX_AUTH="$LOGIN_HOME/.codex"
SYNTH_CODEX_AUTH="$SYNTH_HOME/.codex"
CODEX_REVIEWER_AUTH="$LOGIN_HOME/.codex-reviewer"
CLAUDE_REVIEWER_AUTH="$LOGIN_HOME/.claude-reviewer"
FAKE_AUTH="$TMPROOT/fake-profile-auth"
mkdir -p "$BIN" "$LOGIN_HOME" "$SYNTH_HOME" "$CODEX_AUTH" "$SYNTH_CODEX_AUTH" "$CODEX_REVIEWER_AUTH" "$CLAUDE_REVIEWER_AUTH" "$FAKE_AUTH"

cat > "$BIN/dscl" <<SH
#!/usr/bin/env bash
printf 'NFSHomeDirectory: %s\n' "$LOGIN_HOME"
SH
chmod +x "$BIN/dscl"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$label: expected '$expected', got '$actual'"
}

json_field() {
  local file="$1" field="$2"
  jq -r ".$field" "$file"
}

cd "$ROOT"

login_json="$TMPROOT/login-context.json"
PATH="$BIN:$PATH" HOME="$LOGIN_HOME" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=claude-code \
  bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json read-only" \
  >"$login_json"

assert_eq "login launch durable studio_home" "$LOGIN_HOME/.dev-studio" "$(json_field "$login_json" studio_home)"
assert_eq "login launch project_slug" "generic-dev-studio" "$(json_field "$login_json" project_slug)"
assert_eq "claude host profile" "claude-code" "$(json_field "$login_json" host_profile)"
assert_eq "claude auth_home" "$LOGIN_HOME" "$(json_field "$login_json" auth_home)"
assert_eq "claude github_home" "$LOGIN_HOME" "$(json_field "$login_json" github_home)"

codex_json="$TMPROOT/codex-context.json"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" CODEX_HOME="$CODEX_AUTH" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=codex \
  bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json delegated-host-spawn" \
  >"$codex_json"

assert_eq "codex synthetic launch durable studio_home" "$LOGIN_HOME/.dev-studio" "$(json_field "$codex_json" studio_home)"
assert_eq "codex auth_home" "$CODEX_AUTH" "$(json_field "$codex_json" auth_home)"
assert_eq "codex github_home normalized to login home" "$LOGIN_HOME" "$(json_field "$codex_json" github_home)"
assert_eq "codex runtime owner remains project" "project" "$(json_field "$codex_json" runtime_owner)"
assert_eq "codex data visibility remains private runtime" "private-runtime" "$(json_field "$codex_json" data_visibility)"

codex_implicit_json="$TMPROOT/codex-implicit-context.json"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=codex \
  bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json delegated-host-spawn" \
  >"$codex_implicit_json"

assert_eq "codex synthetic launch implicit auth_home" "$SYNTH_CODEX_AUTH" "$(json_field "$codex_implicit_json" auth_home)"
assert_eq "codex synthetic launch implicit github_home normalized" "$LOGIN_HOME" "$(json_field "$codex_implicit_json" github_home)"

codex_reviewer_json="$TMPROOT/codex-reviewer-context.json"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=codex-reviewer \
  bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json delegated-host-spawn" \
  >"$codex_reviewer_json"

assert_eq "codex reviewer auth_home defaults to login reviewer profile" "$CODEX_REVIEWER_AUTH" "$(json_field "$codex_reviewer_json" auth_home)"
assert_eq "codex reviewer runtime owner" "reviewer" "$(json_field "$codex_reviewer_json" runtime_owner)"

claude_reviewer_json="$TMPROOT/claude-reviewer-context.json"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=claude-reviewer \
  bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json delegated-host-spawn" \
  >"$claude_reviewer_json"

assert_eq "claude reviewer auth_home defaults to login home" "$LOGIN_HOME" "$(json_field "$claude_reviewer_json" auth_home)"
assert_eq "claude reviewer runtime owner" "reviewer" "$(json_field "$claude_reviewer_json" runtime_owner)"

rm -rf "$CODEX_REVIEWER_AUTH"
codex_reviewer_fallback_json="$TMPROOT/codex-reviewer-fallback-context.json"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=codex-reviewer \
  bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json delegated-host-spawn" \
  >"$codex_reviewer_fallback_json"

assert_eq "codex reviewer falls back to synthetic codex profile" "$SYNTH_CODEX_AUTH" "$(json_field "$codex_reviewer_fallback_json" auth_home)"

rm -rf "$SYNTH_CODEX_AUTH"
codex_reviewer_login_fallback_json="$TMPROOT/codex-reviewer-login-fallback-context.json"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=codex-reviewer \
  bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json delegated-host-spawn" \
  >"$codex_reviewer_login_fallback_json"

assert_eq "codex reviewer falls back to logged-in codex profile" "$CODEX_AUTH" "$(json_field "$codex_reviewer_login_fallback_json" auth_home)"

if [ "$(json_field "$codex_json" studio_home)" = "$(json_field "$codex_json" auth_home)" ]; then
  fail "durable Studio state and Codex auth home collapsed to the same root"
fi

fake_json="$TMPROOT/fake-context.json"
PATH="$BIN:$PATH" HOME="$LOGIN_HOME" \
  STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio \
  STUDIO_CONTEXT_HOST_PROFILE=fake-second-profile \
  STUDIO_CONTEXT_AUTH_HOME="$FAKE_AUTH" \
  STUDIO_CONTEXT_GITHUB_HOME="$LOGIN_HOME" \
  bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json delegated-host-spawn" \
  >"$fake_json"

assert_eq "fake profile preserved" "fake-second-profile" "$(json_field "$fake_json" host_profile)"
assert_eq "fake profile explicit auth_home" "$FAKE_AUTH" "$(json_field "$fake_json" auth_home)"

handoff_out="$TMPROOT/handoff.out"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" CODEX_HOME="$CODEX_AUTH" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=codex \
  bash -c ". '$ROOT/scripts/lib-studio-context.sh'; eval \"\$(studio_context_emit_env delegated-host-spawn)\"; printf '%s\n%s\n%s\n' \"\$STUDIO_CONTEXT_STUDIO_HOME\" \"\$STUDIO_CONTEXT_AUTH_HOME\" \"\$STUDIO_CONTEXT_HOST_PROFILE\"" \
  >"$handoff_out"

assert_eq "env handoff studio_home" "$LOGIN_HOME/.dev-studio" "$(sed -n '1p' "$handoff_out")"
assert_eq "env handoff auth_home" "$CODEX_AUTH" "$(sed -n '2p' "$handoff_out")"
assert_eq "env handoff host_profile" "codex" "$(sed -n '3p' "$handoff_out")"

handoff_env="$TMPROOT/context.env"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" CODEX_HOME="$CODEX_AUTH" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=codex \
  bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_env delegated-host-spawn" \
  >"$handoff_env"

PATH="$BIN:$PATH" HOME="$SYNTH_HOME" \
  bash -c ". '$handoff_env'; . '$ROOT/scripts/lib-studio-context.sh'; studio_context_validate delegated-host-spawn"

missing_err="$TMPROOT/missing-auth.err"
if PATH="$BIN:$PATH" HOME="$LOGIN_HOME" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=fake-second-profile \
    bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json delegated-host-spawn" \
    >"$TMPROOT/missing-auth.out" 2>"$missing_err"; then
  fail "missing auth_home unexpectedly passed"
fi
grep -q 'auth_home missing for delegated-host-spawn' "$missing_err" \
  || fail "missing auth_home failure was not loud"

contradictory_err="$TMPROOT/contradictory.err"
if PATH="$BIN:$PATH" HOME="$SYNTH_HOME" CODEX_HOME="$CODEX_AUTH" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=codex \
    STUDIO_CONTEXT_STUDIO_HOME="$SYNTH_HOME/.dev-studio" \
    bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json read-only" \
    >"$TMPROOT/contradictory.out" 2>"$contradictory_err"; then
  fail "synthetic studio_home unexpectedly passed"
fi
grep -q 'studio_home points inside synthetic host home' "$contradictory_err" \
  || fail "synthetic studio_home failure was not loud"

bypass_json="$TMPROOT/bypass-context.json"
bypass_err="$TMPROOT/bypass-context.err"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" CODEX_HOME="$CODEX_AUTH" STUDIO_CONTEXT_PROJECT_SLUG=generic-dev-studio STUDIO_CONTEXT_HOST_PROFILE=codex \
  STUDIO_BYPASS_PARENT_HOME_FLIP=1 \
  bash -c ". '$ROOT/scripts/lib-studio-context.sh'; studio_context_emit_json github-operation" \
  >"$bypass_json" 2>"$bypass_err"

assert_eq "bypass keeps durable studio_home on login root" "$LOGIN_HOME/.dev-studio" "$(json_field "$bypass_json" studio_home)"
assert_eq "bypass routes github_home to caller HOME" "$SYNTH_HOME" "$(json_field "$bypass_json" github_home)"
grep -q 'STUDIO_BYPASS_PARENT_HOME_FLIP active' "$bypass_err" \
  || fail "bypass did not leave explicit stderr evidence"

printf 'PASS: Studio context resolver\n'
