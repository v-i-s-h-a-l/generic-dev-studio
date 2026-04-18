# Shared: Push Notifications

Push queue protocol and trigger rules for iMessage/Telegram notifications via the configured MCPs.

## Push Queue File

```
~/.dev-studio/.runtime/state/push-queue.jsonl
```

Append-only JSONL. Each line is a push event:

```json
{"ts":"2026-04-18T14:32:01Z","agent":"argus","trigger":"review_blocked","task":"T001","message":"Argus blocked T001: secrets found in diff (FilterApplier.swift:42)"}
```

| Field | Type | Notes |
|---|---|---|
| `ts` | ISO8601 | UTC |
| `agent` | string | Who appended this entry |
| `trigger` | string | The event type that triggered the push (see trigger rules below) |
| `task` | string | Task ID or `""` for system events |
| `message` | string | Human-readable. Max 200 chars. No newlines. |

## Append Pattern

```bash
PUSH_FILE=~/.dev-studio/.runtime/state/push-queue.jsonl
mkdir -p ~/.dev-studio/.runtime/state
printf '%s\n' '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","agent":"argus","trigger":"review_blocked","task":"'"$TASK_ID"'","message":"'"$MSG"'"}' >> "$PUSH_FILE"
```

## Trigger Rules (v1)

Agents append to the push queue for these events. The user reads the queue via `/chanakya status`.

| Trigger | Agent | When |
|---|---|---|
| `review_blocked` | Argus | Hard block — compile fail, test fail, secrets, staleness |
| `merge_conflict` | Achilles | Merge step hits a conflict |
| `watch_queue_drained` | Chanakya | `--watch` queue empties (all dispatched tasks done) |
| `build_debt_blocked` | Achilles / Chanakya | Build debt counter crosses 12 |
| `error` | Any | ERROR-level failure in any agent |

Events NOT in the trigger list are written to the event log only (not the push queue).

## v1 Behavior: Queue Only

In v1, agents only **append** to the push queue. No debouncing, no digest bundling, no automatic MCP push calls. The queue is a file the user or Chanakya reads.

**To send a push in v1:** Chanakya `status` reads the push queue and surfaces any unacknowledged entries. If the user wants real-time push, they run `/chanakya status` — or the watch loop surfaces it.

## v2 Target: Digest Bundling (deferred)

In v2, a flush mechanism will:
1. Watch the push queue file.
2. If ≥3 push events arrive within 60 seconds, collapse them into one digest message.
3. Call `mcp__plugin_imessage_imessage__reply` or `mcp__plugin_telegram_telegram__reply` with the digest.
4. Mark sent entries with `"sent": true` to avoid re-sending.

The v2 debounce logic is intentionally not implemented in v1 to avoid over-engineering before we know the notification volume.

## Sending a Push (when needed now)

If you need to send an immediate push outside the queue pattern:

```
# iMessage (use the reply tool with the configured chat_id):
mcp__plugin_imessage_imessage__reply(chat_id="<chat_id>", text="<message>")

# Telegram:
mcp__plugin_telegram_telegram__reply(chat_id="<chat_id>", text="<message>")
```

The chat IDs are in the agent's session context from the MCP configuration. Do not hardcode them in SKILL.md files — they come from the MCP access config.

## Acknowledging Queue Entries

After `/chanakya status` surfaces the push queue, Chanakya marks displayed entries:

```bash
# In-place edit: add "displayed": true to each shown entry
# Simplest implementation: move shown entries to ~/.dev-studio/.runtime/state/push-queue-archive.jsonl
```

The queue file should not grow unboundedly. Chanakya compact sweeps entries older than 7 days.
