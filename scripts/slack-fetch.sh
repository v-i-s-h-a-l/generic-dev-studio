#!/usr/bin/env bash
# slack-fetch.sh — Slack read primitive.
#
# Wraps `conversations.history`, `conversations.replies`, and `users.info` for
# studio callers. Used by `studio-tf-push.sh` Step 7 (build-message composition
# scans recent #testing parents + thread replies for cc-mention attribution),
# and reserved for future Slack ingestion paths (bug-reporter intake, Nabu).
#
# Usage:
#   scripts/slack-fetch.sh history --channel <id> [--limit <n>] [--dry-run]
#   scripts/slack-fetch.sh replies --channel <id> --ts <parent-ts> [--limit <n>] [--dry-run]
#   scripts/slack-fetch.sh user    --user <user-id> [--dry-run]
#
# Output:
#   Live mode: one JSON object per line on stdout. For `history` and `replies`
#              each line is one Slack message (`messages[]` array elements
#              streamed via `jq -c '.messages[]'`). For `user`, a single line
#              with the `user` object. Exit 0 if Slack returned `ok=true`,
#              exit 1 otherwise (the raw response goes to stderr).
#   Dry-run:   prints `URL: <url>` and `PARAMS: <key=value …>` on stdout; exit 0.
#              No token required; the caller can verify URL/param assembly
#              against synthetic fixtures with no Slack credential present.
#
# Token:
#   Read from $STUDIO_SLACK_TOKEN_FILE if set, else ~/.claude/secrets/slack-bot-token.
#   Missing-or-unreadable → fail loud per R14: exit 2, no network call.
#
# Exit codes:
#   0   success (live ok=true, or dry-run clean walk)
#   1   live call returned ok=false, or HTTP error
#   2   bad args / missing token / missing required flag

set -u
umask 022

SUBCOMMAND="${1:-}"
case "$SUBCOMMAND" in
  history|replies|user) shift ;;
  -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") printf 'slack-fetch: subcommand required (history|replies|user)\n' >&2; exit 2 ;;
  *) printf 'slack-fetch: unknown subcommand %s\n' "$SUBCOMMAND" >&2; exit 2 ;;
esac

CHANNEL=""
TS=""
LIMIT=""
USER_ID=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --channel) CHANNEL="${2:?--channel requires value}"; shift 2 ;;
    --ts) TS="${2:?--ts requires value}"; shift 2 ;;
    --limit) LIMIT="${2:?--limit requires value}"; shift 2 ;;
    --user) USER_ID="${2:?--user requires value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    *) printf 'slack-fetch: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$SUBCOMMAND" in
  history)
    [ -n "$CHANNEL" ] || { printf 'slack-fetch history: --channel required\n' >&2; exit 2; }
    URL="https://slack.com/api/conversations.history"
    PARAMS="channel=$CHANNEL"
    [ -n "$LIMIT" ] && PARAMS="$PARAMS&limit=$LIMIT"
    JQ_FILTER='.messages[]'
    ;;
  replies)
    [ -n "$CHANNEL" ] || { printf 'slack-fetch replies: --channel required\n' >&2; exit 2; }
    [ -n "$TS" ]      || { printf 'slack-fetch replies: --ts required\n' >&2; exit 2; }
    URL="https://slack.com/api/conversations.replies"
    PARAMS="channel=$CHANNEL&ts=$TS"
    [ -n "$LIMIT" ] && PARAMS="$PARAMS&limit=$LIMIT"
    JQ_FILTER='.messages[]'
    ;;
  user)
    [ -n "$USER_ID" ] || { printf 'slack-fetch user: --user required\n' >&2; exit 2; }
    URL="https://slack.com/api/users.info"
    PARAMS="user=$USER_ID"
    JQ_FILTER='.user'
    ;;
esac

if [ "$DRY_RUN" = "1" ]; then
  printf 'URL: %s\n' "$URL"
  printf 'PARAMS: %s\n' "$PARAMS"
  exit 0
fi

TOKEN_FILE="${STUDIO_SLACK_TOKEN_FILE:-$HOME/.claude/secrets/slack-bot-token}"
if [ ! -r "$TOKEN_FILE" ]; then
  printf 'slack-fetch: token file %s not readable — refuse to fetch (R14)\n' "$TOKEN_FILE" >&2
  exit 2
fi
TOKEN=$(cat "$TOKEN_FILE")
[ -n "$TOKEN" ] || { printf 'slack-fetch: token file is empty — refuse to fetch (R14)\n' >&2; exit 2; }

CURL_ARGS=(-sSG "$URL" -H "Authorization: Bearer $TOKEN")
OLD_IFS=$IFS; IFS='&'
for kv in $PARAMS; do
  CURL_ARGS+=(--data-urlencode "$kv")
done
IFS=$OLD_IFS
RESPONSE=$(curl "${CURL_ARGS[@]}")

OK=$(printf '%s' "$RESPONSE" | jq -r '.ok // false' 2>/dev/null)
if [ "$OK" != "true" ]; then
  printf '%s\n' "$RESPONSE" >&2
  exit 1
fi

printf '%s' "$RESPONSE" | jq -c "$JQ_FILTER"
exit 0
