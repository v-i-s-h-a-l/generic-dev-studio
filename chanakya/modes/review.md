---
name: Chanakya Review
description: Inbox sweep + event-log processing. Handles regular task debriefs, manual-build-check debriefs, release debriefs, App Store watcher, threshold actions, stale-artifact janitor, event log, feedback reminders, blind-spot detection, studio-feedback ingestion. Also the explicit `/chanakya review` PRD-delta sub-command.
type: mode-pack
snapshots: [debt.json, events-tail.json, feedback-inbox.json]
budget_tokens: 4000
---

# Mode: Review (inbox sweep + event processing + PRD delta)

This mode owns two workflows that share most of their reads:

1. **Inbox sweep (Step 0A–0G)** — invoked at the start of every Chanakya session before any other mode runs, and as the body of `--auto-sweep` ticks.
2. **PRD delta (`/chanakya review`)** — the explicit sub-command where the user pastes updated requirements and Chanakya diffs them against the master plan.

Snapshots consulted: `snapshots/debt.json` for counter state, `snapshots/events-tail.json` for the last ~100 events (freshness: treat as stale if `generated_at` is null or >5 min old — fall back to reading `events/<date>.jsonl` directly from the project memory), `snapshots/feedback-inbox.json` for pending feedback-inbox items (fallback: walk `feedback-inbox/*/` directly if stale).

## Step −1 — Session Launch

On the **first** invocation of `/chanakya` in a session (no `--auto-sweep` flag), proceed directly to Step 0. No prompt about background sweep — the user opts in by passing `--away` or `--auto-sweep` at invocation time.

Read `chanakya_mode.md` to determine current mode. If the file is missing, write it with `mode: at-laptop`.

## Step 0 — Auto-Inbox Sweep (ALWAYS do this first)

Before executing ANY mode, check `~/.dev-studio/<project>/plans/chanakya-inbox/` for unprocessed files. Handle three categories: regular task debriefs (`<task-id>-debrief.md`), manual-build-check debriefs (`build-*-debrief.md`, identified by `Type: manual-build-check` header), and release debriefs (`tf-*-debrief.md` with `Type: testflight-release`, `release-*-debrief.md` with `Type: appstore-release`). Ignore `processed/` and `*-tests.md`.

### 0A — Process each regular task debrief

1. Read the debrief.
2. Update the corresponding task in `chanakya-master.md`:
   - Set status to `done` (or `needs-review` if the debrief flags issues).
   - Record commit hashes and the merge commit from the Branch section.
3. **Update the Build Debt block** (see `_shared/debt-tracking.md`) using the debrief's `build_gate:` field.
4. **Update the Test Debt block** (see `_shared/debt-tracking.md`):
   - If the task is an implementation type (feature/bugfix/refactor), check whether its unit test sub-task (same Group, `Type: test-unit`) is `done` or `verified`. If not, increment the unit test debt counter.
   - Same check for UI test sub-task (`Type: test-ui`) against UI test debt counter.
   - If the task IS a test sub-task (`test-unit`, `test-integration`, `test-ui`), decrement the appropriate counter and remove the parent task from `Untested since`.
5. For every item in the debrief's `## Follow-up Tasks` section, create a **new** task entry:
   - Fresh task ID, `Source:` = originating task ID, status `pending`.
   - If the follow-up is manual-verification of the parent, include the test-case artifact path in Notes.
6. If the debrief has substantive follow-ups, immediately generate briefs for them (same as Brief Generation mode, Steps 3–6). Set their status to `briefed`.
7. **Argus-skip detection.** Parse the debrief's `## Argus Review` section. A debrief counts as *Argus-skipped* when any of these is true:
   - The section is missing entirely.
   - Its body case-insensitively matches `not invoked` / `skipped` / `bypassed` / `did not run`.
   - The verdict is neither `approved` nor `flagged` nor `blocked`.

   Exemptions (never flagged):
   - Task type is `build-check`, `test-suite-run`, `direct (user-run)`, `documentation`, or the task title starts with `TBUILD-` / `TUNIT-` / `TUI-`.
   - The task's Notes explicitly say `argus: not required` (operator override).

   On detection:
   - Emit one event:
     ```json
     {"ts":"…","agent":"chanakya","event":"review_pending","task":"<task-id>","data":{"merge_sha":"<sha>","reason":"argus_skipped_in_debrief"}}
     ```
   - Add `- **Argus:** pending (not invoked in source session — run \`/argus <task-id>\`)` to the task entry in the master plan if the field isn't already present.
   - Append to the push queue so `--away` mode surfaces it.

   `review_pending` is a new event type; add it to `~/.claude/skills/_shared/events.md` → "Cross-agent events" with handler: "Surface in next status output. Banner: `⚠️ Review pending: <task-id> merged without Argus. Run \`/argus <task-id>\` before user verification.`"

8. Move the debrief to `processed/`. Leave `*-tests.md` in place.
9. Report: "Processed T001 — done, 2 follow-ups briefed (T014, T015). Build debt: 7/12. Unit test debt: 3/8. UI test debt: 2/6. Review pending: none." (or `Review pending: T001` when detected.)

### 0B — Process each manual-build-check debrief

1. Read the debrief. Note `HEAD:`, `Covers:`, `result:`, and (if red) the `## Bisect Result` block.
2. **Green result** (`result: pass`):
   - Reset the Build Debt counter to 0.
   - Update `Last green: build-<stamp> (<timestamp>)` and set `HEAD SHA: <sha>`.
   - Clear `Unverified since:` to `[]`.
   - Close any open `TBUILD-<n>` task: set status to `verified` with note "covered by manual build check `build-<stamp>`".
   - Close any open `TBISECT-<n>` task if it covered the same range: set status `verified`, note the pass.
   - If the debt block was in `block` state (≥12 before), clear it — new briefs/runs are unblocked.
3. **Red result** (`result: fail`):
   - Do **not** reset the counter. Keep the block state active regardless of counter value — a confirmed-red main always blocks.
   - Auto-file a P0 fix task:
     - ID: next free `T<nnn>` (not a T-prefix tasks — just the normal sequence).
     - Title: `"Fix red build — <breaking-commit-subject>"`.
     - Priority: `P0` (blocker).
     - Type: `bugfix`.
     - `Source:` = `build-<stamp>`.
     - Description: quote the full `## Bisect Result` from the debrief. List suspect files, breaking commit SHA, error excerpt.
     - Status: `briefed` — the debrief already contains enough context; the task entry doubles as a mini-brief.
   - Tag the Build Debt block with `blocked_by: T<nnn>` so subsequent `/chanakya brief` calls refuse with a useful pointer.
4. **Inconclusive bisect** (`bisect_inconclusive: true`):
   - File a P0 manual-investigation task covering the same range, rather than a specific-commit fix task.
   - Keep block state active.
5. Move the debrief to `processed/`.
6. Report: "Processed manual build check `build-20260415-143200` — green. Debt reset. TBUILD-3 closed." (or red variant with fix-task ID.)

### 0B2 — Process each release debrief

Handle `Type: testflight-release` and `Type: appstore-release` debriefs:

1. Read the debrief. Extract `Build number`, `Version`, `Distribution`, `Git tag` (if App Store), `HEAD`, and the `Covers:` task list.
2. **Add a row to `## Release Log`** in the master plan:
   - Build: `<BUILD_NUMBER>`
   - Version: `<VERSION>`
   - Type: `TestFlight` or `App Store`
   - Date: debrief's `Completed` timestamp
   - Tag: git tag (App Store) or `—` (TestFlight)
   - HEAD: `<HEAD_SHA>`
   - Tasks Included: the `Covers:` list
3. **Tag each task** in the `Covers:` list: append to the task's `Released in:` field:
   - TestFlight: `TF-<BUILD_NUMBER>`
   - App Store: `AS-<BUILD_NUMBER>`
   - If the field already has entries, comma-separate: `TF-3028, TF-3031, AS-3031`
4. Move the debrief to `processed/`.
5. Report: "Processed TestFlight release 3031 — 5 tasks tagged (T015, T016, T017, T018, T019)."
6. **Auto-trigger Slack sync.** After processing a TestFlight release debrief:
   a. Read the project memory file `project_slack_list_sync.md` to check if a Slack list is configured.
   b. If yes, automatically run Sync-Slack mode (Steps 1–7) with `--build <BUILD_NUMBER>` from the debrief.
   c. **Before writing to Slack (Step 6),** present the summary table to the user and ask: "Sync these updates to the Slack bug list? (y/n)".
   d. On confirmation, write. On rejection, skip the write but keep the computed data for manual review.
   e. This is NOT a suggestion — Chanakya proactively runs the sync computation. The only user gate is the write confirmation.

### 0B3 — App Store submission watcher (if any)

If `~/.dev-studio/<project>/.runtime/state/pending-appstore-review.json` exists, invoke `bash scripts/appstore-watch.sh` (best-effort; swallow non-zero exit). The script is idempotent and self-gated on the marker's `next_check_at`, so most calls exit in <50ms without an API call. It piggybacks every `/chanakya` sweep (`status`, `brief`, `ship`, `auto-sweep` tick, etc.) — no separate trigger is needed, and no `--away`/`--auto-sweep` is required.

On terminal App Store state (`PENDING_DEVELOPER_RELEASE` / `READY_FOR_SALE`) the script publishes the draft release, posts a threaded Slack reply on the original `#releases` post, deletes the marker, and emits `appstore_released`. Partial-finalize failures are handled idempotently via flags inside the marker, so the next sweep only retries the unfinished step.

If the marker's `stuck: true` flag is set (≥3 consecutive failures), surface a one-line banner in the sweep summary:

```
⚠️ App Store watcher stuck on <tag> (<N> failures, last: <reason>).
   Inspect ~/.dev-studio/<project>/.runtime/state/pending-appstore-review.json.
```

Read the stuck state cheaply by `grep '"stuck": true'` on the marker file — do not invoke the watcher script just to report status.

No output when the marker is absent, when `resolve_project` doesn't match the marker's project, or when `next_check_at` is in the future.

### 0C — Threshold actions

After 0A and 0B run, evaluate the current Build Debt counter:

- **Counter crosses from 5 → 6** (first time reaching warn threshold, and no open `TBUILD-<n>` exists):
  - Auto-file a new `TBUILD-<n>` task:
    - ID: `TBUILD-<n>` where `<n>` is the next free integer (track via Changelog or a dedicated counter in the Build Debt block).
    - Title: `"Build verification checkpoint"`.
    - Priority: `P0`.
    - Type: `build-check`.
    - `Source:` = `build-debt`.
    - Complexity: `S`.
    - Description: "Run `/achilles build` to verify HEAD is green. Covers: [T015..T020]."
    - Status: `briefed`.
- **Counter in [6, 11], TBUILD-<n> already open**: update its Covers list in-place with the newly added task IDs. Do not file a second TBUILD.
- **Counter crosses 12** (block threshold): no new TBUILD needed (existing one stays P0). Mark Build Debt block state as `block`. The banner on future `/chanakya` and `/chanakya brief` will refuse new work.
- **Counter after reset to 0**: clear block state, close open TBUILD as above.

### 0D — Stale-artifact janitor

**Red-build worktrees/derived-data.** Scan `~/.dev-studio/<project>/worktrees/` and `~/.dev-studio/<project>/derived-data/` for directories matching `build-*` (lowercase, timestamp-stamped):

- If older than 48h AND no open P0 fix task references them in its Source field → remove the directory.
- Otherwise leave in place.

This prevents indefinite accumulation of red-build artifacts while preserving anything the user is actively using.

**Feedback asset retention** (spec: `project_feedback_lifecycle.md`). Scan `~/.dev-studio/<project>/feedback/archive/` and `~/.dev-studio/<project>/chanakya-inbox/assets/`:

1. **Video deletion — at archive time, not here.** `feedback-archive` removes the video and rewrites `video_path` to `(deleted — <filename>, <description>)` *before* the file is unlinked. The janitor only asserts invariants: if a `video_path` in `archive/build-<N>.md` still points at a real file older than 24h post-archive, delete it and rewrite the record (defensive; should be rare).
2. **Screenshot deletion — 7 days after archive.** For each F-record in `archive/build-<N>.md` with an `archived_date:` older than 7 days and a live `screenshot_path:` pointing at a real file: read the file's description from the record's `original_message:` or a one-line summary, rewrite `screenshot_path` to `(deleted — <filename>, <description>)`, then delete the file.
3. **Orphan-asset sweep.** Walk `chanakya-inbox/assets/` recursively. Any file *not referenced* by any `screenshot_path:` or `video_path:` (live or deleted-with-filename) across `feedback/active.md` + `feedback/incoming/` + `feedback/archive/`:
   - If mtime older than 7 days → delete.
   - Otherwise leave (likely freshly attached, awaiting ingestion).
4. **Scaling alerts.** Line-count `feedback/active.md`:
   - >50 records → print a one-line warning banner: "⚠️ `feedback/active.md` has N records; run `/chanakya feedback-archive` to prune."
   - ≥100 records → print a block banner: "⛔ `feedback/active.md` has N records — ingest refused until pruned. Run `/chanakya feedback-archive`." Record `feedback_ingest_blocked: true` in memory so `ingest-*` modes refuse until cleared.

Text descriptions (`original_message`, the "(deleted — …)" replacement string) are preserved permanently — janitor never edits them.

### 0E — Process event log

Read new events from today's event log since the last offset. Schema and offset protocol: `~/.claude/skills/_shared/events.md`.

```bash
PROJECT_MEMORY="$HOME/.claude/projects/-Users-vishalsingh-Documents-Turnip-gg-turnip-ios/memory"
EVENT_FILE="$PROJECT_MEMORY/events/$(date -u +%Y-%m-%d).jsonl"
OFFSET_FILE="$PROJECT_MEMORY/events_offset.md"
```

1. Read current offset from `events_offset.md`. If file missing or date differs from today, reset offset to 0.
2. Read new lines from `$EVENT_FILE` starting at the stored offset.
3. For each new event line, apply these handlers:

| Event | Action |
|---|---|
| `review_flagged` | Auto-file follow-up tasks for each finding in `data.findings`. Create one task per distinct finding category with `Source: argus-review`, priority P2, status `pending`. Do not prompt the user — rule #10 scoped confirmation principle does not gate this. |
| `review_blocked` | Surface the block to the user in the next status output. Append to push queue. |
| `review_pending` | Surface in next status with banner: "⚠️ Review pending: `<task>` merged without Argus. Run `/argus <task>` before user verification." Append to push queue. Cleared when a later `review_approved`/`review_flagged`/`review_blocked` event lands for the same task. |
| `task_awaiting_user` | Surface the question to the user in the next status output. **Always** append to push queue (in away mode this is the only notification channel; in at-laptop mode the banner still helps). Include `data.question` verbatim in the push payload, truncated to 200 chars. Pair with the corresponding `<task-id>-debrief.md` (`status: blocked_awaiting_input`) for full context. |
| `task_verified` | Archive `<project-memory>/reviews/review_<task>.md` to `reviews/archive/` if it exists. |
| `review_approved` | Delete `/tmp/argus-<task>.xcresult` if it exists. |
| `task_completed` | Note the task ID for potential follow-up brief generation. **Call `<scripts>/achilles-queue.sh drain`** to hand the freed worker its next task (no-op if queue is empty). |
| `brief_failed` / `merge_conflict` / `review_blocked` / `task_awaiting_user` / `task_rescued` | Call `<scripts>/achilles-queue.sh drain` in addition to the row-specific action — every one of these frees the worker slot without emitting `task_completed`, so skipping drain would strand the rest of the queue. |
| `task_rescued` | Surface to user in next status: "Task `<task>` moved to rescue (reason: `<reason>`, worker: `<worker-N>`). See `worker-<N>/rescue/<task>-stuck.md` if reason=`silent_stuck`, or the task file's sidecar for `timeout`." Append to push queue — rescue is a hard block from the user's perspective. |
| `base_stale` | Surface to user in next status: "Task <task> requires rebase — base advanced." |
| `merge_conflict` | Surface to user. Append to push queue. |
| `build_debt_blocked` | Append to push queue. |
| `feedback_ingested` | No master-plan mutation. Surface count in next status ("N new feedback records: F0XX..F0YY"). |
| `feedback_archived` | Regenerate reporters/ index entries for affected reporters (scan archive file + active). |
| `root_cause_promoted` | Note the pattern label in the next status output so the user knows a new root-cause entry exists. |

4. Update offset to current EOF of `$EVENT_FILE`:
   ```bash
   NEW_OFFSET=$(wc -c < "$EVENT_FILE" 2>/dev/null || echo 0)
   ```
   Write updated `events_offset.md`.

5. Emit `task_verified` event when review-feedback promotes a task (Step in review-feedback mode):
   ```json
   {"ts":"...","agent":"chanakya","event":"task_verified","task":"<task-id>","data":{"method":"review-feedback"}}
   ```

6. Emit `cleanup_completed` event after each compact run:
   ```json
   {"ts":"...","agent":"chanakya","event":"cleanup_completed","task":"","data":{"archived":<N>,"freed_gb":<X>}}
   ```

### 0E2 — Process feedback reminders

Read the `## Reminders` section of `feedback/active.md`. For each row whose `due_at` is in the past:

1. Parse `type` and `args`.
2. Dispatch:
   - `type: ingest-reminder` with `args: <channel> <thread-ts> [--build N]` → invoke Ingest-Thread mode with those args (silent — summarise in next status output).
3. Delete the row on success. On error, leave it and surface the error in the next status.

This mechanism replaces a real scheduler — the adaptive-backoff sweep already ticks at most every 15–120 min, which is adequate granularity for a 24h post-`push-tf` reminder.

### 0E3 — Blind-spot detection (usage-analysis signals)

Best-effort detection of workflow signals that aren't directly observable from other agents. Each detection emits at most one event per occurrence; skip silently on any read error (the event log is a hint, not a source of truth).

**Auto-emitted by dispatch scripts (no sweep action needed):**

| Signal | Where it fires | Event |
|---|---|---|
| User re-dispatched a task that already completed | `scripts/achilles-dispatch.sh` calls `emit_predispatch_signals` (in `lib-paths.sh`) which scans the last 14 days of event logs for a prior `task_completed` with the same `task`. The event's `prior_completed_at` pins the ts so latency can be derived. | `task_redispatched` |
| User answered a `task_awaiting_user` | Same helper — fires when a prior `task_awaiting_user` exists for the task and is newer than its last `task_awaiting_user_resolved`. `wait_duration_s = now − await_ts`. | `task_awaiting_user_resolved` |

Both are wired via `emit_predispatch_signals` in `scripts/lib-paths.sh`. No Chanakya code path needs to detect them — they fire every time a task is routed through the dispatch script.

**Chanakya sweep-time detections:**

`scripts/detect-edits.sh` handles the two mtime-based scans in one shot. Invoke it once per sweep, ideally right after Step 0E2 before user-visible output:

```bash
<scripts>/detect-edits.sh --quiet
```

It emits `brief_edited` and `debrief_edited` directly via `append_event`, maintains its own idempotency markers (`<project-memory>/brief_edit_seen.txt`, `debrief_seen.txt`), and returns 0 even when the current project has no briefs or debriefs. Chanakya treats a non-zero exit as non-fatal.

The remaining two sweep-time signals need Chanakya's in-session context and don't belong in a script:

| Signal | When to emit | Concrete recipe |
|---|---|---|
| User overrode an Argus flag | After a user confirms "ship anyway" / "merge anyway" on a `review_flagged` task in `ship`, `review-feedback`, or `intake` mode. | Source `<scripts>/lib-paths.sh` and call `append_event chanakya review_override "<task-id>" '{"review_file":"<path>","finding_count":<n>,"reason":"<≤100 chars>"}'`. Emit once per override decision, not once per finding. |
| Build-debt counter incremented | Inside inbox sweep: after applying a debrief that carries `build_gate: lsp-only` (or an equivalent test-skip marker) and updating the counter in `chanakya-master.md`. | `append_event chanakya build_debt_incremented "<task-id>" '{"counter":"build","new_value":<n>,"trigger":"xs_skip"}'`. Fires on every increment — the existing `build_debt_warned` / `build_debt_blocked` events still own threshold crossings; this one enables size-vs-debt analysis. |

Markers (`brief_edit_seen.txt`, `debrief_seen.txt`) are simple text files; wipe them on `compact` so a re-edit after archival can re-emit.

### 0F — Studio-feedback inbox ingestion (delegated to script)

Run `scripts/ingest-feedback.sh` and surface any stdout lines in the session greeting (e.g. `ingested feedback-inbox/turnip-ios/<file>.md → <issue-url>`). The script is gated on `resolve_project() == generic-dev-studio` — in any other project's session it silent-exits, so this step is safe to invoke unconditionally.

The same script runs automatically on SessionStart for this repo (`.claude/settings.json`), so most ingestions complete before Step 0F fires. Re-running here is idempotent: processed files are never touched.

For the per-scope dispatch contract (`generic-dev-studio` → sanitized `gh issue create`; `upstream` → stderr notice, leave in place; `work-project` → private only), see the script header and the Feedback mode's Studio-Feedback section.

### 0G — Proceed to the requested mode

For `auto-sweep` invocations: determine whether the sweep was blank (no events processed, no inbox items found, no reminders fired). Update `auto_sweep_state.md` accordingly (increment or reset `consecutive_blank`), compute the next delay via adaptive backoff, re-schedule, then stop.

## Sub-command: `/chanakya review` (PRD delta)

### Step 1 — Get the updated requirements

Ask: "Paste the updated PRD, describe the changes, or give me the file path."

### Step 2 — Diff against master plan

For each change, classify:
- **No impact** — doesn't touch any existing task
- **Pending/briefed task affected** — update description, mark brief as stale
- **Done/verified task needs rework** — set status to `needs-rework`, explain delta
- **New work** — create new task entries

### Step 3 — Present change report

```
PRD Delta:
- T001 (export flow) — VERIFIED, affected: new HEIF format requirement
  Rework scope: add HEIF encoder option, ~S complexity
- T003 (texture browse) — BRIEFED, affected: grid changed from 2-col to 3-col
  Brief is stale, needs regeneration
- NEW: T006 — Watermark toggle (not in previous PRD)
```

### Step 4 — Apply and report

Update master plan. Auto-regenerate any stale briefs (run Brief Generation mode for each). Report which briefs were updated.

## Cross-cutting

Debt counter rules, banners, and brief-mode refusal: see `_shared/debt-tracking.md`.
Principles (including Task Status Lifecycle and session-completion event): `_shared/chanakya-principles.md`.
