#!/usr/bin/env bash
# tests-write-round.sh — Step 7 round artifact write for /chanakya test-flow.
#
# Thin wrapper that mints a UUIDv7 and delegates to lib-ledger's
# write_round_artifact, which handles the YAML write, round_state_changed
# event, and index rebuild. Legacy round markdown is read-only historical
# input post-#245 A.4/A.5.
#
# Usage:
#   scripts/tests-write-round.sh <round-number> <scope> <tasks-csv> <body-file>
#
# Stdout: the minted round UUID (so the caller can emit downstream events /
# link the round into other artifacts).
#
# Exit codes:
#   0  round written
#   2  missing args or body-file

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

ROUND_NUM="${1:-}"
SCOPE="${2:-}"
TASKS_CSV="${3:-}"
BODY_FILE="${4:-}"

if [ -z "$ROUND_NUM" ] || [ -z "$SCOPE" ] || [ -z "$BODY_FILE" ]; then
  printf 'usage: tests-write-round.sh <round-number> <scope> <tasks-csv> <body-file>\n' >&2
  exit 2
fi

if [ ! -f "$BODY_FILE" ]; then
  printf 'error: body file not found: %s\n' "$BODY_FILE" >&2
  exit 2
fi

uuid=$(mint_uuidv7)
body=$(cat "$BODY_FILE")

write_round_artifact "$uuid" "$ROUND_NUM" "$SCOPE" "$TASKS_CSV" "$body"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'error: write_round_artifact failed rc=%s\n' "$rc" >&2
  exit "$rc"
fi

printf '%s\n' "$uuid"
exit "$rc"
