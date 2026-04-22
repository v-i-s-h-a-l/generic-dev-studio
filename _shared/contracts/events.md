---
name: Event Log
description: Schema, atomicity contract, and offset-marker conventions for the shared append-only event log.
type: reference
---

# Shared: Event Log

All agents write to a shared append-only event log. Chanakya tails it on wake.

## File Location

```
<project-memory>/events/<YYYY-MM-DD>.jsonl
```

`<project-memory>` = `~/.claude/projects/-Users-vishalsingh-Documents-Turnip-gg-turnip-ios/memory/` (resolved at runtime from `~/.claude/skills/_shared/primitives/file-locations.md`).

One JSONL file per calendar day. Agents never rotate or delete these files — Chanakya compact handles rotation (see `_shared/rules/cleanup-policy.md`).

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
| `task_awaiting_user` | Subagent cannot pick a default and must block for user input. Always paired with a debrief at `status: blocked_awaiting_input`. | `question` (≤200 chars), `brief_excerpt` (≤200 chars, the Phase-0 block or the ambiguous spec line), `mode` (`autonomous`\|`interactive`) |
| `task_cancelled` | User cancelled a pending or in-flight task (`scripts/achilles-cancel.sh` or an Achilles abort). Paired with no `task_completed`. | `stage` (`pending`\|`in_flight`\|`merged`), `reason` (`user_abort`\|`replaced`\|`stale_brief`\|`other`), `worker` (`worker-N` if known) |
| `task_rescued` | Worker moved a task to `rescue/` — either `timeout` (rc=124 from `gtimeout`) or `silent_stuck` (rc=0 with no debrief written). Emitted by `scripts/achilles-worker.sh`. Visible equivalent of the rescue file, so Chanakya can surface + push without polling worker directories. | `reason` (`timeout`\|`silent_stuck`), `timeout_s` (only on timeout), `rc`, `debrief_written` (0\|1), `worker` (`worker-N`) |

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
| `task_dispatched` | Chanakya writes a task file to a worker inbox (Ship/Dispatch/Sweep-debt modes) | `worker` (`worker-N` or `any`), `flags` (string), `from_brief` (`true`\|`false`) |
| `feedback_ingested` | Feedback record minted from a Slack thread / DM / channel | `source`, `channel`, `thread_ts`, `reporter`, `build` |
| `feedback_archived` | Feedback record promoted to per-build archive | `build`, `reporter`, `linked_task` |
| `root_cause_promoted` | A `root_cause` label crossed 2+ instances and got its own file | `instances` (array of F-ids) |
| `task_redispatched` | Chanakya dispatches a task whose last prior event was already `task_completed` (or that appears in worker `done/`). Signals brief or output defect — user wasn't satisfied with the first run. | `prior_merge_sha` (if resolvable), `reason` (`user_retry`\|`follow_up`\|`rebase_needed`\|`other`) |
| `brief_edited` | Detected in Step 0E: the brief file's mtime moved forward after the most recent `task_dispatched` for that task, and no `task_completed` has closed it. Signals brief-template defect — user had to hand-edit before the worker picked it up. | `age_s_since_dispatch`, `lines_changed_est` (optional; `wc -l` delta if prior size was recorded) |
| `debrief_edited` | Detected in Step 0E: a processed debrief file's mtime moved forward after it landed in `plans/chanakya-inbox/processed/`. Signals debrief-template defect — user corrected something the agent wrote. | `age_s_since_process`, `lines_changed_est` (optional) |
| `review_override` | User elects to merge / ship despite a `review_flagged` (e.g. "ship anyway" during ship or review-feedback). Signals potential false-positive Argus rule. | `review_file`, `finding_count`, `reason` (short string; ≤100 chars) |
| `review_pending` | Emitted by Chanakya in Step 0A when a processed debrief's `## Argus Review` section indicates Argus was skipped / not invoked on a non-exempt task. Cleared implicitly when a later `review_approved` / `review_flagged` / `review_blocked` lands for the same task. | `merge_sha`, `reason` (`argus_skipped_in_debrief`) |
| `task_awaiting_user_resolved` | Counterpart to `task_awaiting_user` — emitted when the user's answer lands (detected by a subsequent `task_redispatched` or explicit intake of the brief update). Enables "time waiting on user" measurement. | `wait_duration_s`, `resolved_by` (`user_answered`\|`timeout`\|`cancelled`) |
| `build_debt_incremented` | Counter goes up on an XS/S LSP-only merge (every skip, not only threshold crossings). Chanakya emits during inbox sweep when the incoming debrief's `build_gate: lsp-only`. Enables "which task sizes drive debt" analysis. | `counter` (`build`\|`test_unit`\|`test_ui`), `new_value`, `trigger` (`xs_skip`\|`s_skip`\|`tdd_skip`\|`other`) |
| `appstore_submitted` | `/fullSendToAppStore` writes the `pending-appstore-review.json` marker after posting to `#releases`. Task field = release tag. | `build`, `version`, `submitted_at` |
| `appstore_state_checked` | `scripts/appstore-watch.sh` completed a non-terminal ASC state poll. One emit per real API call (self-gated on `next_check_at`, so far less than one per sweep). | `state` (ASC `appStoreState` value) |
| `appstore_released` | Watcher observed terminal state (`PENDING_DEVELOPER_RELEASE` / `READY_FOR_SALE`) and finalized: draft published, Slack reply posted, marker deleted. | `final_state`, `tag` |
| `appstore_watch_stuck` | Watcher hit ≥3 consecutive failures (JWT, ASC query, `gh release edit`, or Slack post). Marker's `stuck: true` flag is set; next sweep will surface a banner and retry. | `reason`, `failures`, `state` (optional — present when failure was during finalize) |
| `legacy_artifact_read` | A runtime script fell back to a pre-Phase-2.6 path because the post-2.6 ledger shape was unavailable (`plans/index.yaml` missing, `plans/debriefs/` absent, or `yq` unavailable on the machine). One emit per sweep per domain — makes the transition to the canonical layout observable. Task field is empty. | `domain` (`briefs`\|`debriefs`), `reason` (`plans_index_missing`\|`plans_debriefs_missing`\|`yq_unavailable`), `caller` (script name) |
| `legacy_event_source_retired` | `scripts/migrate-ledger.sh` cleanup phase moved a pre-2.6 event-log sibling (e.g. `event-log.jsonl`, `events.log`) to `archive/2026-pre-2.6/legacy-event-sources/` after verifying parity against the canonical day-partitioned files. Task field is empty. | `source` (relative path), `source_lines`, `canonical_lines` |
| `feedback_placeholder_pruned` | `scripts/migrate-ledger.sh` cleanup phase removed a `.gitkeep`-only subdir under `feedback/` (e.g. `feedback/root-causes/`). Recreated lazily on first real write. Task field is empty. | `path` (relative path) |

### Snapshot events (router-pattern)

Emitted by `scripts/chanakya-snap.sh` (producer side) and by mode packs that consume snapshots (reader side). See `_shared/patterns/router-pattern.md` §Freshness and fallback for the contract. Agent field is `chanakya` on all five.

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `snapshot_generated` | A snapshot producer finishes an atomic write successfully | `domain` (`briefs`\|`debt`\|`feedback-inbox`\|`events-tail`), `duration_ms`, `size_bytes`, `caller` (script name or `prewarm`) |
| `snapshot_hit` | Mode pack read a snapshot whose `generated_at` is within the mode's staleness window | `domain`, `age_seconds` |
| `snapshot_miss` | Mode pack tried to read a snapshot that is absent, empty, or corrupt (fell back to full-load) | `domain`, `reason` (`not_generated`\|`missing_file`\|`corrupt`) |
| `snapshot_stale` | Mode pack read a snapshot whose `generated_at` exceeds the mode's staleness window (fell back to full-load) | `domain`, `age_seconds`, `staleness_window_seconds` |
| `snapshot_failed` | Producer hit an error before the atomic mv — previous snapshot left in place | `domain`, `error` (short string; ≤100 chars) |

**Why five.** `generated` / `failed` on the producer side let us alert if a domain stops refreshing. `hit` / `miss` / `stale` on the consumer side let us measure the actual pre-warm win (ratio of hits to total reads) and detect when a staleness window is too tight (high stale-rate on a domain with frequent writes).

### Cross-agent events (every agent emits)

| Event | Emitted when | Typical `data` keys |
|---|---|---|
| `agent_session_completed` | Final step of any agent session (any mode) | `mode` (e.g. `ship`, `T001`, `auto-sweep`), `duration_s`, `tokens` (`{input, output, cache_read, cache_write}` — best-effort; may be omitted if not available), `files_read` (count), `files_written` (count) |
| `stale_index_lock_removed` | `safe_git_commit` (see `_shared/primitives/safe-git.md`) cleared a stale `.git/index.lock` with no live holder. Tracks frequency so the producer side can be root-caused if it rises. | `repo` (absolute path from `git rev-parse --show-toplevel`), `caller_skill` (e.g. `pushTFBuild`, `achilles-merge`, `gcpr`) |
| `dual_write_partial` | A Phase 2.6 dual-writer (see `_shared/patterns/dual-write-transition.md`) succeeded on the YAML side but failed on the legacy counterpart. Emitted by `scripts/lib-ledger.sh` helpers. Paired with exit code `3` from the caller so the next sweep surfaces the drift rather than it silently compounding. | `subject_kind` (`task`\|`brief`\|`round`\|`release`\|`debrief`\|`review`), `subject_uuid`, `legacy_path`, `reason` (short string; e.g. `permission_denied`\|`disk_full`\|`concurrent_lock`\|`other`) |

**Why `agent_session_completed`.** Without this we can't measure context cost or session duration per agent. Treat as required at the end of every Chanakya / Achilles / Argus session, regardless of how the session terminated. If token counts aren't available to the agent at emit time, omit the `tokens` key — duration alone is still useful.

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

For push notifications, agents append to the per-project push queue at `~/.dev-studio/<project>/.runtime/state/push-queue.jsonl` (resolve via `scripts/lib-paths.sh resolve_push_queue`) — see `_shared/primitives/push-notifications.md`.
