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

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

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

printf 'PR_REVIEWER_ELIGIBLE=1\n'
printf 'HOST=%s\n' "$HOST"
printf 'MANIFEST=%s\n' "${manifest#"$REPO_ROOT/"}"
printf 'SPAWN_COMMAND=%s\n' "$spawn_command"
