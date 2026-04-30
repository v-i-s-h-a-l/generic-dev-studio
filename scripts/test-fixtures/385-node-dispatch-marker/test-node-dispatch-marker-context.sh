#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t node-dispatch-marker.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

# shellcheck source=../../../lib-remote-failure.sh
. "$ROOT/scripts/lib-remote-failure.sh"

log="$TMPROOT/remote.log"
cat >"$log" <<'EOF'
CompileSwift Sources/App.swift
Sources/App.swift:12:7: error: cannot find 'value' in scope
node-dispatch: remote command exit code: 65
node-dispatch: exit marker missing for 11111111-2222-3333-4444-555555555555
node-dispatch: remote log tail for 11111111-2222-3333-4444-555555555555 follows
EOF

reason=$(remote_failure_reason "$log")
[ "$reason" = "remote_marker_writer_failed" ] || {
  printf 'FAIL: expected remote_marker_writer_failed, got %s\n' "$reason" >&2
  exit 1
}

data='{"reason":"remote_marker_writer_failed","exit_code":125}'
enriched=$(remote_enrich_marker_failure "$data" "$log")

printf '%s' "$enriched" | jq -e '.remote_command_exit_code == 65' >/dev/null || {
  printf 'FAIL: missing remote_command_exit_code in %s\n' "$enriched" >&2
  exit 1
}

printf '%s' "$enriched" | jq -e '.remote_log_tail | contains("cannot find")' >/dev/null || {
  printf 'FAIL: missing remote_log_tail context in %s\n' "$enriched" >&2
  exit 1
}

grep -q 'remote command exit code:' "$ROOT/scripts/node-dispatch.sh" || {
  printf 'FAIL: node-dispatch does not log remote command exit code\n' >&2
  exit 1
}

grep -q 'exit marker missing' "$ROOT/scripts/node-dispatch.sh" || {
  printf 'FAIL: node-dispatch does not report exit marker missing\n' >&2
  exit 1
}

grep -q 'remote log tail' "$ROOT/scripts/node-dispatch.sh" || {
  printf 'FAIL: node-dispatch does not include remote log tail\n' >&2
  exit 1
}

printf 'PASS: node-dispatch marker context\n'
