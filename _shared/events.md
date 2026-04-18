# Shared: Event Log

All agents write to a shared append-only event log. Chanakya tails it on wake.

## File Location

```
<project-memory>/events/<YYYY-MM-DD>.jsonl
```

`<project-memory>` = `~/.claude/projects/-Users-vishalsingh-Documents-Turnip-gg-turnip-ios/memory/` (resolved at runtime from `~/.claude/skills/_shared/file-locations.md`).

One JSONL file per calendar day. Agents never rotate or delete these files — Chanakya compact handles rotation (see `_shared/cleanup-policy.md`).

## Event Schema

Every event is a single JSON object on one line:

```json
{"ts":"2026-04-18T14:32:01Z","agent":"achilles","event":"task_completed","task":"T001","data":{}}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `ts` | ISO8601 string (UTC) | yes | `date -u +%Y-%m-%dT%H:%M:%SZ` |
| `agent` | `achilles` \| `argus` \| `chanakya` | yes | |
| `event` | string | yes | See event catalog below |
| `task` | string | yes* | Task ID (`T001`, `build-20260418-143000`). Use `""` for system events. |
| `data` | object | yes | Event-specific payload. May be `{}`. |

## Atomicity Requirement

**Events MUST fit in a single line of ≤ 4096 bytes.** POSIX guarantees `O_APPEND` writes are atomic on pipes and regular files when the write is ≤ PIPE_BUF (4096 bytes on macOS/Linux). Exceeding this risks interleaved writes from concurrent agents.

- Keep `data` payloads concise. Truncate long strings (e.g., error excerpts at 200 chars).
- If a payload would exceed 4KB, split into multiple events or link to an artifact file.

## Append Pattern

```bash
EVENT_FILE="$PROJECT_MEMORY/events/$(date -u +%Y-%m-%d).jsonl"
mkdir -p "$(dirname "$EVENT_FILE")"
printf '%s\n' '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","agent":"achilles","event":"task_completed","task":"T001","data":{}}' >> "$EVENT_FILE"
```

Use `printf '%s\n'` (not `echo`) — portable and avoids trailing-space issues.

## Event Catalog

### Achilles events

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `brief_started` | Achilles begins Step 1 (load spec) | `size`, `gate_selected` |
| `brief_completed` | All steps done, debrief written | `gate`, `merge_sha` |
| `brief_failed` | Any unrecoverable failure | `reason`, `step` |
| `task_started` | Step 2 — task claimed, branch created | `branch`, `base_sha` |
| `task_completed` | Step 9 — merge succeeded | `merge_sha` |
| `task_merged` | Merge lock released | `merge_sha` |
| `review_requested` | Achilles calls Argus before merge | `worktree`, `derived_data` |
| `review_approved` | Argus returned approve | `review_file` |
| `review_flagged` | Argus returned flag | `review_file`, `finding_count` |
| `review_blocked` | Argus returned block | `review_file`, `block_reason` |
| `merge_conflict` | Merge failed with conflict | `branch`, `files` |
| `build_debt_warned` | Build debt crosses warn threshold | `counter`, `threshold` |
| `build_debt_blocked` | Build debt crosses block threshold | `counter` |

### Argus events

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `review_requested` | Argus begins review | `task`, `size`, `worktree` |
| `review_approved` | All checks pass | `checks_run` |
| `review_flagged` | Non-blocking findings | `findings` (array of strings) |
| `review_blocked` | Hard block — cannot merge | `block_reason`, `check` |
| `test_run_started` | Test phase begins (M/L only) | `slot`, `suite` |
| `test_run_passed` | Tests green | `duration_s`, `test_count` |
| `test_run_failed` | Tests red | `failing_tests` (array) |
| `base_stale` | Base branch advanced since branch point | `base_sha`, `branch_sha` |
| `review_scoped` | A scope cap was triggered (diff cap, file cap, or xs_skip) | `cap` (`diff_size`\|`file_count`\|`xs_skip`), `value`, `limit` |

### Chanakya events

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `task_verified` | review-feedback promotes task | `method` (`review-feedback` \| `test-flow`) |
| `cleanup_completed` | compact sweep finishes | `archived`, `freed_gb` |

## Offset Marker (Consumer Pattern)

Chanakya maintains a byte offset in project memory to avoid re-processing events on every wake:

**File:** `<project-memory>/events_offset.md`

```markdown
# Event Log Offset
date: 2026-04-18
offset: 4096
```

On wake, Chanakya reads from `offset` bytes into today's JSONL file to EOF, processes new events, then updates the offset to the new EOF position.

**Offset reset:** When `date` in the offset file differs from today, reset offset to 0 and update the date field. (New file, no prior events to skip.)

**Reading from offset:**
```bash
tail -c +$((OFFSET + 1)) "$EVENT_FILE"   # +1 because tail -c counts from 1
```

After processing, update offset:
```bash
OFFSET=$(wc -c < "$EVENT_FILE")
```

## Push Queue

For push notifications, agents append to the per-project push queue at `~/.dev-studio/<project>/.runtime/state/push-queue.jsonl` (resolve via `scripts/lib-paths.sh resolve_push_queue`) — see `_shared/push-notifications.md`.
