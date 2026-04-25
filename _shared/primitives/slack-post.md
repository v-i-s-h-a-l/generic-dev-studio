---
name: Slack Post Primitives
description: Shared Slack bot token loading, chat.postMessage pattern, thread_ts usage, and <!here> rules
type: reference
---

# Slack Post Primitives

## Token Loading

Load the bot token once before any Slack API calls:

```bash
SLACK_BOT_TOKEN=$(cat ~/.claude/secrets/slack-bot-token)
```

The token file is stored out-of-repo at `~/.claude/secrets/slack-bot-token` (chmod 600). If the file is missing, halt and ask the user to run `/chanakya sync-slack --configure-token`.

## chat.postMessage Pattern

```bash
curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"channel\":\"CHANNEL_ID\",\"text\":\"MESSAGE_TEXT\"}"
```

Escape newlines as `\n` and any double quotes in the message text before embedding in the JSON `-d` payload.

## Thread Replies (thread_ts)

To post a reply into an existing thread, add `"thread_ts":"$PARENT_TS"` to the JSON body. Capture `$PARENT_TS` from the `ts` field in the parent message response — and **assert it is non-empty before posting any reply**. If `PARENT_TS` is empty, the reply silently degrades to a second top-level message, which is the failure mode in issue #159.

```bash
# Capture parent ts, with explicit error handling — never let the variable
# default to empty and silently emit a second top-level message.
PARENT_RESPONSE=$(curl -sS -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"channel\":\"CHANNEL_ID\",\"text\":\"MESSAGE_TEXT\"}")

PARENT_TS=$(printf '%s' "$PARENT_RESPONSE" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['ts'] if d.get('ok') else '')" 2>/dev/null)

if [ -z "$PARENT_TS" ]; then
  printf 'slack-post: parent message did not return a ts — halting before thread reply to avoid double parent post (issue #159).\n' >&2
  printf '  Response was: %s\n' "$PARENT_RESPONSE" >&2
  exit 1
fi
```

**Single-post invariant.** Each pipeline run must call `chat.postMessage` for the parent **exactly once**. If a retry / fallback path could re-post, gate it behind `[ -z "$PARENT_TS" ]` so the second call only fires when the first genuinely failed (and even then, the reply path is skipped — not silently retargeted as a new top-level).

```bash
# Forbidden — silent re-target produces #159's double-parent bug:
# curl -d "{\"channel\":..., \"text\":\"detail\"}"   # missing thread_ts!
#
# Required — explicit thread_ts every reply, asserted non-empty above:
curl -sS -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"channel\":\"CHANNEL_ID\",\"thread_ts\":\"$PARENT_TS\",\"text\":\"DETAIL\"}"
```

## <!here> Rule

Use `<!here>` only in top-level (non-thread) messages. Slack does not propagate `<!here>` in thread replies — never include it there.
