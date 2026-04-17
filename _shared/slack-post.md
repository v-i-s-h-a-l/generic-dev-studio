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

To post a reply into an existing thread, add `"thread_ts":"$PARENT_TS"` to the JSON body. Capture `$PARENT_TS` from the `ts` field in the parent message response:

```bash
PARENT_TS=$(curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"channel\":\"CHANNEL_ID\",\"text\":\"MESSAGE_TEXT\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['ts'])")
```

## <!here> Rule

Use `<!here>` only in top-level (non-thread) messages. Slack does not propagate `<!here>` in thread replies — never include it there.
