#!/usr/bin/env bash
# slack-post.sh — Slack `chat.postMessage` write primitive.
#
# Formalizes `_shared/primitives/slack-post.md` as a callable script. Used by
# `studio-tf-push.sh` (Step 9) and any future studio caller that needs to post
# to Slack. Token loading, payload assembly, and the parent-once invariant from
# the primitive doc all live here in one place.
#
# Usage:
#   scripts/slack-post.sh --channel <id> (--text <text> | --blocks-file <path>) \
#                         [--thread-ts <ts>] [--dry-run]
#
# Flags:
#   --channel <id>        Slack channel id or name. Required.
#   --text <text>         message text. Mutually exclusive with --blocks-file.
#   --blocks-file <path>  path to a file containing a JSON array of Block Kit
#                         blocks. The script wraps it as the `blocks` field;
#                         `--text` (when also passed) becomes the fallback.
#   --thread-ts <ts>      post as a thread reply to the parent at <ts>.
#                         Asserted non-empty per primitive's parent-once rule.
#   --dry-run             print the JSON payload that would be POSTed and the
#                         target URL, then exit 0. No network call. No token
#                         required (the gate that the live path enforces).
#
# Token:
#   Read from $STUDIO_SLACK_TOKEN_FILE if set (for fixtures + smoke tests), else
#   from ~/.dev-studio/<project>/secrets/slack-bot-token. Missing-or-unreadable
#   → fail loud per R14: exit 2, no network call, no silent skip.
#
# Output:
#   Live mode: prints the Slack API JSON response on stdout. Exit 0 if the
#              response has `"ok":true`, exit 1 otherwise (with the response
#              body still on stdout for the caller to surface).
#   Dry-run:   prints `URL: <url>` and `PAYLOAD: <json>` on stdout; exit 0.
#
# Exit codes:
#   0   success (live ok=true, or dry-run clean walk)
#   1   live call returned ok=false, or HTTP error
#   2   bad args / missing token / missing required flag

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-release-config.sh
. "$SCRIPT_DIR/lib-release-config.sh"

CHANNEL=""
TEXT=""
BLOCKS_FILE=""
THREAD_TS=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --channel) CHANNEL="${2:?--channel requires value}"; shift 2 ;;
    --text) TEXT="${2:?--text requires value}"; shift 2 ;;
    --blocks-file) BLOCKS_FILE="${2:?--blocks-file requires value}"; shift 2 ;;
    --thread-ts) THREAD_TS="${2:?--thread-ts requires value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    *) printf 'slack-post: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$CHANNEL" ] || { printf 'slack-post: --channel required\n' >&2; exit 2; }
if [ -z "$TEXT" ] && [ -z "$BLOCKS_FILE" ]; then
  printf 'slack-post: --text or --blocks-file required\n' >&2; exit 2
fi
if [ -n "$BLOCKS_FILE" ] && [ ! -r "$BLOCKS_FILE" ]; then
  printf 'slack-post: --blocks-file %s not readable\n' "$BLOCKS_FILE" >&2; exit 2
fi

# Build payload. Use jq -n so every value is JSON-escaped exactly once.
build_payload() {
  local args=(--arg channel "$CHANNEL")
  local filter='{channel: $channel}'
  if [ -n "$TEXT" ]; then
    args+=(--arg text "$TEXT")
    filter="$filter + {text: \$text}"
  fi
  if [ -n "$BLOCKS_FILE" ]; then
    args+=(--slurpfile blocks "$BLOCKS_FILE")
    filter="$filter + {blocks: \$blocks[0]}"
  fi
  if [ -n "$THREAD_TS" ]; then
    args+=(--arg thread_ts "$THREAD_TS")
    filter="$filter + {thread_ts: \$thread_ts}"
  fi
  jq -nc "${args[@]}" "$filter"
}

PAYLOAD=$(build_payload) || { printf 'slack-post: payload assembly failed\n' >&2; exit 2; }
URL="https://slack.com/api/chat.postMessage"

if [ "$DRY_RUN" = "1" ]; then
  printf 'URL: %s\n' "$URL"
  printf 'PAYLOAD: %s\n' "$PAYLOAD"
  exit 0
fi

load_release_config || {
  printf 'slack-post: could not resolve release config project\n' >&2
  exit 2
}
TOKEN_FILE=$(release_slack_token_file)
if [ ! -r "$TOKEN_FILE" ]; then
  printf 'slack-post: token file %s not readable — refuse to post (R14)\n' "$TOKEN_FILE" >&2
  exit 2
fi
TOKEN=$(cat "$TOKEN_FILE")
[ -n "$TOKEN" ] || { printf 'slack-post: token file is empty — refuse to post (R14)\n' >&2; exit 2; }

RESPONSE=$(curl -sS -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data "$PAYLOAD")

printf '%s\n' "$RESPONSE"
OK=$(printf '%s' "$RESPONSE" | jq -r '.ok // false' 2>/dev/null)
[ "$OK" = "true" ] || exit 1
exit 0
