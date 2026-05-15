#!/usr/bin/env bash
# lib-host-eligibility.sh - host eligibility smoke checks and triage records.
#
# This library is intentionally sourceable and side-effect-light. It runs the
# non-mutating smoke command declared in a host profile and emits one JSON record
# per check.
#
# Public functions:
#   host_eligibility_check <host_id>
#
# host_eligibility_check emits JSON with:
#   host_id, outcome, detail, duration_ms, smoke_command
#
# Outcomes:
#   eligible
#   binary-missing
#   auth-stale
#   auth-fresh-but-failed
#
# Classified outcomes return 0. Contract or tooling failures return non-zero and
# report details on stderr.

# No `set -e` here - sourced into scripts that choose their own shell policy.

HOST_ELIGIBILITY_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
HOST_ELIGIBILITY_REPO_ROOT=$(cd "$HOST_ELIGIBILITY_LIB_DIR/.." && pwd)

# shellcheck source=scripts/lib-paths.sh
. "$HOST_ELIGIBILITY_LIB_DIR/lib-paths.sh"
# shellcheck source=scripts/lib-host-profiles.sh
. "$HOST_ELIGIBILITY_LIB_DIR/lib-host-profiles.sh"

: "${HOST_ELIGIBILITY_LAST_ERROR:=}"

_host_eligibility_fail() {
  HOST_ELIGIBILITY_LAST_ERROR="$*"
  printf 'lib-host-eligibility: %s\n' "$*" >&2
  return 1
}

_host_eligibility_now_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

_host_eligibility_duration_ms() {
  local start_ms="$1" end_ms duration_ms
  end_ms=$(_host_eligibility_now_ms)
  duration_ms=$((end_ms - start_ms))
  [ "$duration_ms" -ge 0 ] || duration_ms=0
  printf '%s\n' "$duration_ms"
}

_host_eligibility_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    _host_eligibility_fail "jq is required for host eligibility JSON emission"
    return 127
  }
}

_host_eligibility_emit_record() {
  local host_id="$1" outcome="$2" detail="$3" duration_ms="$4" smoke_command="$5"

  _host_eligibility_require_jq || return $?
  jq -n \
    --arg host_id "$host_id" \
    --arg outcome "$outcome" \
    --arg detail "$detail" \
    --arg duration_ms "$duration_ms" \
    --arg smoke_command "$smoke_command" \
    '{
      host_id: $host_id,
      outcome: $outcome,
      detail: $detail,
      duration_ms: ($duration_ms | tonumber),
      smoke_command: $smoke_command
    }'
}

_host_eligibility_binary_available() {
  local binary_path="$1"
  case "$binary_path" in
    */*) [ -x "$binary_path" ] ;;
    *) command -v "$binary_path" >/dev/null 2>&1 ;;
  esac
}

_host_eligibility_expression_end() {
  local input="$1" start="$2" len i depth char next
  len=${#input}
  i=$((start + 2))
  depth=1

  while [ "$i" -lt "$len" ]; do
    char="${input:$i:1}"
    next=""
    [ $((i + 1)) -lt "$len" ] && next="${input:$((i + 1)):1}"

    if [ "$char" = '$' ] && [ "$next" = "{" ]; then
      depth=$((depth + 1))
      i=$((i + 2))
      continue
    fi
    if [ "$char" = "}" ]; then
      depth=$((depth - 1))
      if [ "$depth" -eq 0 ]; then
        printf '%s\n' "$i"
        return 0
      fi
    fi
    i=$((i + 1))
  done

  _host_eligibility_fail "unterminated resolver expression in profile value: $input"
}

_host_eligibility_codex_auth_home() {
  local login_home="$1"
  if [ -n "${CODEX_WORKER_HOME:-}" ]; then
    printf '%s\n' "$CODEX_WORKER_HOME"
    return 0
  fi
  if [ -n "${CODEX_HOME:-}" ]; then
    printf '%s\n' "$CODEX_HOME"
    return 0
  fi
  if studio_home_is_synthetic "${HOME:-}" && [ -d "${HOME:-}/.codex" ]; then
    printf '%s\n' "$HOME/.codex"
    return 0
  fi
  printf '%s\n' "$login_home/.codex"
}

_host_eligibility_expand_expr() {
  local expr="$1" login_home="$2" github_home="$3" env_name fallback env_value

  case "$expr" in
    login_home)
      printf '%s\n' "$login_home"
      return 0
      ;;
    github_home)
      printf '%s\n' "$github_home"
      return 0
      ;;
    codex_auth_home)
      _host_eligibility_codex_auth_home "$login_home"
      return 0
      ;;
  esac

  case "$expr" in
    env.*:-*)
      env_name="${expr#env.}"
      env_name="${env_name%%:-*}"
      fallback="${expr#env.}"
      fallback="${fallback#"$env_name":-}"
      _host_eligibility_validate_env_name "$env_name" || return 1
      env_value=$(printenv "$env_name" 2>/dev/null || true)
      if [ -n "$env_value" ]; then
        printf '%s\n' "$env_value"
      else
        _host_eligibility_expand_value "$fallback" "$login_home" "$github_home"
      fi
      return $?
      ;;
    env.*)
      env_name="${expr#env.}"
      _host_eligibility_validate_env_name "$env_name" || return 1
      printenv "$env_name" 2>/dev/null || true
      return 0
      ;;
  esac

  _host_eligibility_fail "unsupported resolver expression in profile value: \${$expr}"
}

_host_eligibility_validate_env_name() {
  local env_name="$1"
  case "$env_name" in
    ''|[0-9]*|*[!A-Za-z0-9_]*)
      _host_eligibility_fail "unsupported env resolver expression name: $env_name"
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

_host_eligibility_expand_value() {
  local input="$1" login_home="$2" github_home="$3" output i len char next end expr expanded
  output=""
  i=0
  len=${#input}

  while [ "$i" -lt "$len" ]; do
    char="${input:$i:1}"
    next=""
    [ $((i + 1)) -lt "$len" ] && next="${input:$((i + 1)):1}"

    if [ "$char" = '$' ] && [ "$next" = "{" ]; then
      end=$(_host_eligibility_expression_end "$input" "$i") || return 1
      expr="${input:$((i + 2)):$((end - i - 2))}"
      expanded=$(_host_eligibility_expand_expr "$expr" "$login_home" "$github_home") || return 1
      output="${output}${expanded}"
      i=$((end + 1))
      continue
    fi

    output="${output}${char}"
    i=$((i + 1))
  done

  printf '%s\n' "$output"
}

_host_eligibility_resolve_profile_value() {
  local value="$1" login_home github_home
  login_home=$(resolve_user_login_home 2>/dev/null) || {
    _host_eligibility_fail "cannot resolve login_home for host profile expression"
    return 1
  }
  github_home=$(resolve_parent_home_for_github 2>/dev/null) || {
    _host_eligibility_fail "cannot resolve github_home for host profile expression"
    return 1
  }
  _host_eligibility_expand_value "$value" "$login_home" "$github_home"
}

_host_eligibility_first_signal() {
  local stderr_file="$1" stdout_file="$2" signal
  signal=$(sed -n '1p' "$stderr_file" 2>/dev/null | tr '\n' ' ' | cut -c 1-240)
  [ -n "$signal" ] || signal=$(sed -n '1p' "$stdout_file" 2>/dev/null | tr '\n' ' ' | cut -c 1-240)
  printf '%s\n' "$signal"
}

_host_eligibility_output_looks_auth_stale() {
  local stderr_file="$1" stdout_file="$2"
  grep -Eiq \
    '(auth|authentication|credential|token|expired|revoked|unauthori[sz]ed|forbidden|not[[:space:]]+logged|log[ -]?in|sign[ -]?in|401|403)' \
    "$stderr_file" "$stdout_file" 2>/dev/null
}

_host_eligibility_mktemp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/host-eligibility.XXXXXX" 2>/dev/null \
    || mktemp -d -t host-eligibility.XXXXXX
}

host_eligibility_check() {
  local host_id="${1:-}" start_ms profile_json binary_path auth_home_template github_home_template smoke_command
  local auth_home github_home duration_ms tmpdir stdout_file stderr_file smoke_rc detail outcome

  [ -n "$host_id" ] || {
    _host_eligibility_fail "usage: host_eligibility_check <host_id>"
    return 2
  }

  start_ms=$(_host_eligibility_now_ms)
  profile_json=$(host_profile_get "$host_id") || return 1
  binary_path=$(printf '%s\n' "$profile_json" | jq -r '.binary_path')
  auth_home_template=$(printf '%s\n' "$profile_json" | jq -r '.auth_home')
  github_home_template=$(printf '%s\n' "$profile_json" | jq -r '.github_home')
  smoke_command=$(printf '%s\n' "$profile_json" | jq -r '.eligibility_smoke_command')

  if ! _host_eligibility_binary_available "$binary_path"; then
    duration_ms=$(_host_eligibility_duration_ms "$start_ms")
    _host_eligibility_emit_record \
      "$host_id" \
      "binary-missing" \
      "host binary not found or not executable: $binary_path" \
      "$duration_ms" \
      "$smoke_command"
    return 0
  fi

  auth_home=$(_host_eligibility_resolve_profile_value "$auth_home_template") || return 1
  github_home=$(_host_eligibility_resolve_profile_value "$github_home_template") || return 1

  if [ -z "$auth_home" ] || [ ! -d "$auth_home" ]; then
    duration_ms=$(_host_eligibility_duration_ms "$start_ms")
    _host_eligibility_emit_record \
      "$host_id" \
      "auth-stale" \
      "auth home is missing or unreadable: ${auth_home:-<empty>}" \
      "$duration_ms" \
      "$smoke_command"
    return 0
  fi

  if [ -z "$github_home" ] || [ ! -d "$github_home" ]; then
    duration_ms=$(_host_eligibility_duration_ms "$start_ms")
    _host_eligibility_emit_record \
      "$host_id" \
      "auth-stale" \
      "GitHub home is missing or unreadable: ${github_home:-<empty>}" \
      "$duration_ms" \
      "$smoke_command"
    return 0
  fi

  tmpdir=$(_host_eligibility_mktemp_dir) || {
    _host_eligibility_fail "failed to create smoke output directory"
    return 1
  }
  stdout_file="$tmpdir/stdout"
  stderr_file="$tmpdir/stderr"

  (
    cd "$HOST_ELIGIBILITY_REPO_ROOT" || exit 127
    HOME="$auth_home" \
      CLAUDE_HOME="$auth_home" \
      CODEX_HOME="$auth_home" \
      CODEX_WORKER_HOME="$auth_home" \
      GITHUB_HOME="$github_home" \
      STUDIO_CONTEXT_AUTH_HOME="$auth_home" \
      STUDIO_CONTEXT_GITHUB_HOME="$github_home" \
      STUDIO_CONTEXT_HOST_PROFILE="$host_id" \
      bash -c "$smoke_command"
  ) >"$stdout_file" 2>"$stderr_file"
  smoke_rc=$?

  duration_ms=$(_host_eligibility_duration_ms "$start_ms")
  if [ "$smoke_rc" -eq 0 ]; then
    rm -rf "$tmpdir"
    _host_eligibility_emit_record \
      "$host_id" \
      "eligible" \
      "smoke command completed successfully" \
      "$duration_ms" \
      "$smoke_command"
    return 0
  fi

  detail=$(_host_eligibility_first_signal "$stderr_file" "$stdout_file")
  if _host_eligibility_output_looks_auth_stale "$stderr_file" "$stdout_file"; then
    outcome="auth-stale"
    detail="smoke command reported stale authentication: ${detail:-no output}"
  else
    outcome="auth-fresh-but-failed"
    detail="smoke command exited $smoke_rc: ${detail:-no output}"
  fi
  rm -rf "$tmpdir"

  _host_eligibility_emit_record \
    "$host_id" \
    "$outcome" \
    "$detail" \
    "$duration_ms" \
    "$smoke_command"
}
