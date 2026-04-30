#!/usr/bin/env bash
# Shared parsing for remote node-dispatch failure context.

remote_failure_reason() {
  local log="$1"
  if [ ! -r "$log" ]; then
    printf 'remote_harness_failure'
    return 0
  fi
  if grep -Eq 'command not found|No such file or directory|cd: .*No such|xcodebuild: not found|swift: not found' "$log"; then
    printf 'remote_shell_path_failed'
  elif grep -q 'exit marker missing' "$log"; then
    printf 'remote_marker_writer_failed'
  elif grep -q 'success marker missing' "$log"; then
    printf 'remote_marker_writer_failed'
  else
    printf 'build_invocation_failed'
  fi
}

remote_reported_exit_code() {
  local log="$1"
  [ -r "$log" ] || return 1
  awk -F': ' '
    /node-dispatch: remote command exit code: / { code=$NF }
    END {
      if (code ~ /^[0-9]+$/) {
        print code
        exit 0
      }
      exit 1
    }
  ' "$log"
}

remote_enrich_marker_failure() {
  local data="$1" log="$2" lines code tail_text out
  command -v jq >/dev/null 2>&1 || { printf '%s' "$data"; return 0; }
  [ -r "$log" ] || { printf '%s' "$data"; return 0; }

  lines="${REMOTE_FAILURE_TAIL_LINES:-40}"
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  tail_text=$(tail -n "$lines" "$log" 2>/dev/null || printf '')
  out=$(printf '%s' "$data" | jq -c --arg tail "$tail_text" '. + {remote_log_tail:$tail}')

  code=$(remote_reported_exit_code "$log" 2>/dev/null || printf '')
  case "$code" in
    ''|*[!0-9]*) printf '%s' "$out" ;;
    *) printf '%s' "$out" | jq -c --argjson code "$code" '. + {remote_command_exit_code:$code}' ;;
  esac
}
