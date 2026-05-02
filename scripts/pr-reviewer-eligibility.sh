#!/usr/bin/env bash
# pr-reviewer-eligibility.sh — preflight a host for headless PR review.
#
# Usage:
#   scripts/pr-reviewer-eligibility.sh [host]
#
# The check is intentionally stricter than Achilles worker dispatch:
# PR reviewers must be headless, no-prompt, and no-secret. The parent studio
# session owns GitHub actions through gh; reviewer sessions read diffs and
# report verdicts/fixes only.

set -u
umask 022

HOST="${1:-${STUDIO_REVIEW_HOST:-codex-reviewer}}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SMOKE_TIMEOUT_SEC="${STUDIO_REVIEWER_SMOKE_TIMEOUT_SEC:-45}"
CALLER_HOME="${HOME:-}"

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

LOGIN_HOME=$(resolve_user_login_home 2>/dev/null || true)

fail() {
  printf 'PR_REVIEWER_ELIGIBLE=0\n'
  printf 'REASON=%s\n' "$1"
  [ -n "${2:-}" ] && printf 'DETAIL=%s\n' "$2"
  exit 1
}

yaml_field() {
  local file="$1" key="$2"
  grep -E "^${key}:[[:space:]]" "$file" 2>/dev/null \
    | head -1 \
    | sed "s/^${key}:[[:space:]]*//" \
    | tr -d '"'"'"
}

first_line() {
  sed -n '1p' "$1" 2>/dev/null | tr '\n' ' ' | cut -c 1-240
}

run_smoke_gate() {
  local tmpdir payload stdout_file stderr_file reviewer_home reviewer_codex_home reviewer_claude_config_dir
  tmpdir=$(mktemp -d -t pr-reviewer-smoke.XXXXXX) || fail smoke_tmp_failed "mktemp failed"
  payload="$tmpdir/payload.md"
  stdout_file="$tmpdir/stdout"
  stderr_file="$tmpdir/stderr"
  reviewer_home="$tmpdir/home"
  mkdir -p "$reviewer_home"
  printf '# Reviewer smoke payload\n\nEmit one STUDIO_REVIEW_VERDICT line.\n' > "$payload"

  reviewer_codex_home=""
  reviewer_claude_config_dir=""
  case "$HOST" in
    codex*|*codex*)
      reviewer_codex_home="${CODEX_REVIEWER_HOME:-${CODEX_HOME:-}}"
      if [ -z "$reviewer_codex_home" ]; then
        if [ -n "$CALLER_HOME" ] && [ -d "$CALLER_HOME/.codex" ]; then
          reviewer_codex_home="$CALLER_HOME/.codex"
        elif [ -n "$LOGIN_HOME" ] && [ -d "$LOGIN_HOME/.codex" ]; then
          reviewer_codex_home="$LOGIN_HOME/.codex"
        fi
      fi
      [ -n "$reviewer_codex_home" ] && [ -d "$reviewer_codex_home" ] || {
        rm -rf "$tmpdir"
        fail smoke_auth_unavailable "codex reviewer auth home not found; set CODEX_REVIEWER_HOME or CODEX_HOME"
      }
      ;;
    claude*|*claude*)
      reviewer_claude_config_dir="${CLAUDE_REVIEWER_CONFIG_DIR:-${LOGIN_HOME:+$LOGIN_HOME/.claude-reviewer}}"
      [ -n "$reviewer_claude_config_dir" ] || {
        rm -rf "$tmpdir"
        fail smoke_auth_unavailable "claude reviewer config dir not found; set CLAUDE_REVIEWER_CONFIG_DIR or HOME"
      }
      mkdir -p "$reviewer_claude_config_dir" || {
        rm -rf "$tmpdir"
        fail smoke_auth_unavailable "failed to create claude reviewer config dir: $reviewer_claude_config_dir"
      }
      ;;
  esac

  # shellcheck disable=SC2206
  local smoke_argv=( $spawn_command )
  local timeout_argv=()
  case "$SMOKE_TIMEOUT_SEC" in
    ''|*[!0-9]*) fail invalid_smoke_timeout "STUDIO_REVIEWER_SMOKE_TIMEOUT_SEC must be numeric" ;;
    0) ;;
    *)
      if command -v gtimeout >/dev/null 2>&1; then
        timeout_argv=(gtimeout "$SMOKE_TIMEOUT_SEC")
      elif command -v timeout >/dev/null 2>&1; then
        timeout_argv=(timeout "$SMOKE_TIMEOUT_SEC")
      else
        rm -rf "$tmpdir"
        fail smoke_timeout_unavailable "reviewer smoke timeout requires gtimeout or timeout"
      fi
      ;;
  esac

  local prompt="Studio reviewer smoke test. Read $payload and print exactly one line: STUDIO_REVIEW_VERDICT=approved"
  local smoke_cmd=()
  if [ "${#timeout_argv[@]}" -gt 0 ]; then
    smoke_cmd=("${timeout_argv[@]}" "${smoke_argv[@]}" "$prompt")
  else
    smoke_cmd=("${smoke_argv[@]}" "$prompt")
  fi
  local smoke_rc
  case "$HOST" in
    codex*|*codex*)
      ( cd "$REPO_ROOT" && env -i \
        PATH="$PATH" \
        HOME="$reviewer_home" \
        LANG="${LANG:-C.UTF-8}" \
        USER="${USER:-}" \
        ${reviewer_codex_home:+CODEX_HOME="$reviewer_codex_home"} \
        STUDIO_HOST="$HOST" \
        REVIEW_PAYLOAD="$payload" \
        "${smoke_cmd[@]}" >"$stdout_file" 2>"$stderr_file" )
      smoke_rc=$?
      ;;
    *)
      ( cd "$REPO_ROOT" && env -i \
      PATH="$PATH" \
      HOME="$reviewer_home" \
      LANG="${LANG:-C.UTF-8}" \
      USER="${USER:-}" \
      ${reviewer_claude_config_dir:+CLAUDE_CONFIG_DIR="$reviewer_claude_config_dir"} \
      STUDIO_HOST="$HOST" \
      REVIEW_PAYLOAD="$payload" \
      "${smoke_cmd[@]}" </dev/null >"$stdout_file" 2>"$stderr_file" )
      smoke_rc=$?
      ;;
  esac
  if [ "$smoke_rc" -ne 0 ]; then
    local detail
    detail=$(first_line "$stderr_file")
    [ -n "$detail" ] || detail=$(first_line "$stdout_file")
    rm -rf "$tmpdir"
    fail smoke_failed "${detail:-reviewer smoke command exited non-zero}"
  fi

  local verdict_count verdict detail
  verdict_count=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$stdout_file" | wc -l | tr -d ' ')
  verdict=$(sed -n 's/^STUDIO_REVIEW_VERDICT=//p' "$stdout_file")
  if [ "$verdict_count" != "1" ]; then
    detail=$(first_line "$stdout_file")
    rm -rf "$tmpdir"
    fail smoke_no_verdict "expected exactly one STUDIO_REVIEW_VERDICT line; found $verdict_count${detail:+; first_stdout=$detail}"
  fi
  case "$verdict" in
    approved|approved_with_fixes|blocked) ;;
    *)
      rm -rf "$tmpdir"
      fail smoke_invalid_verdict "$verdict"
      ;;
  esac
  rm -rf "$tmpdir"
}

registry="$REPO_ROOT/hosts/registry.yaml"
[ -f "$registry" ] || fail missing_registry "$registry"
command -v yq >/dev/null 2>&1 || fail missing_yq "yq is required to read hosts/registry.yaml"

detect_binary=$(yq -r ".\"$HOST\".detect_binary // \"\"" "$registry" 2>/dev/null)
[ -n "$detect_binary" ] && [ "$detect_binary" != "null" ] || fail unknown_host "$HOST"
command -v "$detect_binary" >/dev/null 2>&1 || fail missing_cli "$detect_binary"

manifest=$(resolve_capabilities_manifest "$HOST" "$REPO_ROOT") \
  || fail missing_manifest "host=$HOST has no capabilities_path"
[ -f "$manifest" ] || fail missing_manifest "$manifest"

spawn_command=$(yaml_field "$manifest" spawn_command)
secret_scope=$(yaml_field "$manifest" secret_scope)
sandbox_profile=$(yaml_field "$manifest" sandbox_profile)
reviewer_profile=$(yaml_field "$manifest" reviewer_profile)

[ -n "$spawn_command" ] || fail missing_spawn_command "$manifest"
[ "$secret_scope" = "none" ] || fail secret_scope_floor_unmet "secret_scope=$secret_scope"
[ "$sandbox_profile" != "none" ] || fail sandbox_floor_unmet "sandbox_profile=none"
[ "$reviewer_profile" = "true" ] || fail not_reviewer_profile "$manifest"

case "$spawn_command" in
  *"--ask-for-approval never"*|*"--approval-policy never"*|*"-c approval_policy=never"*|*"--config approval_policy=never"*|*"--permission-mode dontAsk"*) ;;
  *) fail prompt_floor_unmet "spawn_command must force no-prompt execution" ;;
esac

case "$spawn_command" in
  *"--dangerously-bypass-approvals-and-sandbox"*) fail unsafe_spawn_command "dangerous sandbox bypass is forbidden" ;;
  *"--dangerously-skip-permissions"*) fail unsafe_spawn_command "dangerous permission bypass is forbidden" ;;
esac

case "$HOST" in
  claude*|*claude*)
    # shellcheck disable=SC2206
    spawn_argv=( $spawn_command )
    case "$spawn_command" in
      *" -p "*|*" --print "*) ;;
      *) fail interactive_spawn_command "Claude reviewer must use -p/--print" ;;
    esac
    case "$spawn_command" in
      *"--setting-sources project"*) ;;
      *) fail inherited_user_config "Claude reviewer must restrict setting sources to project" ;;
    esac
    case "$spawn_command" in
      *"--disable-slash-commands"*) ;;
      *) fail inherited_slash_commands "Claude reviewer must disable slash commands" ;;
    esac
    case "$spawn_command" in
      *"--no-session-persistence"*) ;;
      *) fail persistent_session_state "Claude reviewer must disable session persistence" ;;
    esac
    case "$spawn_command" in
      *"--strict-mcp-config"*) ;;
      *) fail inherited_mcp_config "Claude reviewer must use strict MCP config" ;;
    esac
    tools_value=""
    i=0
    while [ "$i" -lt "${#spawn_argv[@]}" ]; do
      case "${spawn_argv[$i]}" in
        --tools)
          i=$((i + 1))
          tools_value="${spawn_argv[$i]:-}"
          ;;
        --tools=*)
          tools_value="${spawn_argv[$i]#--tools=}"
          ;;
      esac
      i=$((i + 1))
    done
    [ "$tools_value" = "Read,Grep,Glob" ] \
      || fail write_tool_floor_unmet "Claude reviewer tools must exactly equal Read,Grep,Glob"
    "${spawn_argv[@]}" --help >/dev/null 2>&1 \
      || fail invalid_spawn_command "Claude reviewer spawn command is not accepted by the installed CLI"
    ;;
  codex*|*codex*)
    case "$spawn_command" in
      *"--ignore-user-config"* ) ;;
      *) fail inherited_user_config "Codex reviewer must pass --ignore-user-config" ;;
    esac
    case "$spawn_command" in
      *"--ignore-rules"* ) ;;
      *) fail inherited_rules "Codex reviewer must pass --ignore-rules" ;;
    esac
    case "$spawn_command" in
      *"--ephemeral"* ) ;;
      *) fail persistent_session_state "Codex reviewer must pass --ephemeral" ;;
    esac
    # shellcheck disable=SC2206
    spawn_argv=( $spawn_command )
    "${spawn_argv[@]}" --help >/dev/null 2>&1 \
      || fail invalid_spawn_command "Codex reviewer spawn command is not accepted by the installed CLI"
    ;;
esac

case "${STUDIO_INTERNAL_REVIEWER_SKIP_SMOKE:-0}" in
  1|true|yes) smoke_status="skipped" ;;
  *)
    run_smoke_gate
    smoke_status="passed"
    ;;
esac

printf 'PR_REVIEWER_ELIGIBLE=1\n'
printf 'HOST=%s\n' "$HOST"
printf 'MANIFEST=%s\n' "${manifest#"$REPO_ROOT/"}"
printf 'SPAWN_COMMAND=%s\n' "$spawn_command"
printf 'SMOKE=%s\n' "$smoke_status"
