---
name: Chanakya Inbox Sweep
description: Pre-dispatch inbox sweep procedure. Runs Steps 0A–0G before every Chanakya mode — regular task debriefs (task-mode + direct-debrief), manual-build-check debriefs, release debriefs, App Store watcher, threshold actions, stale-artifact janitor, event log processing, feedback reminders, blind-spot detection, studio-feedback ingestion. Split out of modes/review.md on 2026-04-22 so non-review invocations don't pay for PRD-delta prose they never use.
type: mode-pack
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: [debt.json, events-tail.json, feedback-inbox.json]
budget_tokens: 5000
reads:
  - plans/index.yaml                               # post-migration relational index
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/briefs/*.yaml                            # brief lookup for follow-up task brief-regeneration
  - plans/debriefs/*.yaml                          # post-migration canonical (schema: _shared/schemas/debrief.md, debrief@2.0.0 — both task + direct-debrief modes)
  - plans/reviews/*.yaml                           # argus verdicts (schema: _shared/schemas/review.md)
  - plans/releases/*.yaml                          # release-state linkage for release debriefs
  - plans/feedback/*.yaml                          # feedback state snapshot for reminders
  - plans/chanakya-master.md                       # legacy fallback until Commit H
  - plans/chanakya-inbox/<task-id>-debrief.md      # legacy debrief fallback until Commit H
  - plans/chanakya-inbox/build-*-debrief.md        # legacy manual-build-check debrief until Commit H
  - plans/chanakya-inbox/{tf,release}-*-debrief.md # legacy release debrief until Commit H
  - feedback/active.md                             # reminder reads
  - .runtime/state/pending-appstore-review.json    # legacy watcher marker (migrates to plans/releases/<id>.yaml asc_metadata at Commit H)
  - events/<date>.jsonl                            # via scripts/read-events.sh
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
writes:
  - plans/tasks/<task-id>.yaml                     # state transitions per _shared/state-machines/task-lifecycle.md + links.debrief + links.reviews
  - plans/releases/<release-id>.yaml               # release state transitions on release-debrief ingest
  - plans/feedback/<feedback-id>.yaml              # feedback state transitions from reminder dispatch
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh
  - plans/chanakya-master.md                       # legacy master-plan mutation until Commit H
  - plans/chanakya-inbox/processed/                # legacy debrief move destination until Commit H
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Inbox Sweep (pre-dispatch Step 0)

This mode pack owns the pre-dispatch procedure that fires before every Chanakya mode. Not a user-invoked mode on its own — the router always runs it as Step 0 before dispatching to the user's requested mode pack. Also the body of `--auto-sweep` ticks and the dedicated `/chanakya sweep` subcommand (which runs Step 0 and exits).

PRD-delta has moved to `modes/review.md`. If you pasted an updated PRD into this session, see there.

Snapshots consulted: `snapshots/debt.json` for counter state, `snapshots/events-tail.json` for the last ~100 events (freshness: treat as stale if `generated_at` is null or >5 min old — fall back to reading `events/<date>.jsonl` directly from the project memory), `snapshots/feedback-inbox.json` for pending feedback-inbox items (fallback: walk `feedback-inbox/*/` directly if stale).

## Step −1 — Session Launch

On the **first** invocation of `/chanakya` in a session (no `--auto-sweep` flag), proceed directly to Step 0. No prompt about background sweep — the user opts in by passing `--away` or `--auto-sweep` at invocation time.

Read `chanakya_mode.md` to determine current mode. If the file is missing, write it with `mode: at-laptop`.

## Step 0 — Auto-Inbox Sweep (ALWAYS do this first)

Before executing ANY mode, enumerate unprocessed debrief artifacts. Post-migration surface: glob `~/.dev-studio/<project>/plans/debriefs/*.yaml` and filter to those with `state: emitted` (missing `state` field reads as `emitted` for pre-2.0.1 back-compat). The `state` field replaces the earlier "lookup via parent-task history" scheme — it works uniformly for both task-mode debriefs (which also have parent-task history) and direct-debriefs (which don't). Legacy surface: walk `~/.dev-studio/<project>/plans/chanakya-inbox/` for unprocessed files (regular task debriefs `<task-id>-debrief.md`, manual-build-check debriefs `build-*-debrief.md` with `Type: manual-build-check`, release debriefs `tf-*-debrief.md` with `Type: testflight-release`, `release-*-debrief.md` with `Type: appstore-release`; ignore `processed/` and `*-tests.md`). Emit one `legacy_artifact_read` event per legacy-surface hit so the transition is visible.

**Uniform debrief ingest (task + direct-debrief).** Debriefs authored by Achilles in either `task` mode (with `task_id` + `brief_id` set) or the new `direct-debrief` mode (both null; surface: `/achilles debrief`) share the same schema (`debrief@2.0.1`). Ingest reads them uniformly — no branching on `mode`. A direct-debrief with `task_id: null` skips Step 0A's task-linkage steps (steps 1–4) and goes straight to follow-up minting (step 5) + state flip (step 8). Semantic linking against prior debriefs and open issues (`similar_to`, `duplicate_of`, `part_of`) is Phase 2.7 scope — current sweep only does the mechanical ingest.

### 0A — Process each regular task debrief

1. Read the debrief. Post-migration surface: parse `plans/debriefs/<debrief-id>.yaml` per schema `_shared/schemas/debrief.md` (`debrief@2.0.0`); structured fields (`decisions`, `tests`, `diff_summary`, `argus_review`, `follow_ups`, `build_gate`, `debt`) are typed arrays/objects — no section-header parsing. Legacy fallback parses `## Summary` / `## Build Verification` / `## Follow-up Tasks` / `## Argus Review` section headers in the markdown debrief.
2. Update the corresponding task. Post-migration: transition `plans/tasks/<task-id>.yaml` state per `_shared/state-machines/task-lifecycle.md` — typical flow is `argus-reviewed → merged` on merge; append the `history:` entry, set `links.debrief = <debrief-id>`, append `links.reviews` with the `argus_review.review_id` when present. Legacy fallback mutates `chanakya-master.md`: sets status to `done` (or `needs-review` when the debrief flags issues), records commit hashes + merge commit.
3. **Update the Build Debt block** (see `_shared/rules/debt-tracking.md`) using the debrief's `build_gate` field (`lsp-only` vs `full-green`) — typed enum in YAML, no parsing needed.
4. **Update the Test Debt block** (see `_shared/rules/debt-tracking.md`):
   - If the task is an implementation type (feature/bugfix/refactor), check whether its unit test sub-task (sibling by title-prefix, type `test-unit`) is `merged`/`verified`. If not, increment the unit test debt counter.
   - Same check for UI test sub-task (type `test-ui`) against UI test debt counter.
   - If the task IS a test sub-task (`test-unit`, `test-integration`, `test-ui`), decrement the appropriate counter and remove the parent from `Untested since`.
5. For every item in the debrief's `follow_ups[]` array (YAML) / `## Follow-up Tasks` section (legacy), mint a **new** task entry: post-migration writes a fresh `plans/tasks/<new-task-id>.yaml` per schema with `state: proposed`, title referencing the originating task, `links.feedback` empty; legacy fallback writes a new row into `chanakya-master.md` with `Source: <task-id>`, status `pending`. **For direct-debriefs** (`task_id: null`), use the debrief-id as the source reference (`links.source_debrief: <debrief-id>` in the new task's YAML, `Source: <debrief-id[:8]>` in the legacy row) — there is no originating task to reference.
6. If the debrief has substantive follow-ups, immediately generate briefs for them (invoke Brief Generation mode). Post-migration: brief mode transitions the new task's state to `briefed` and writes `plans/briefs/<brief-id>.yaml`; legacy path sets status to `briefed` in the master plan.
7. **Argus-skip detection.** Read the debrief's `argus_review` object (YAML) or `## Argus Review` section (legacy). A debrief counts as *Argus-skipped* when any of these is true:
   - Post-migration: `argus_review.status == not-invoked` and the task's type is NOT in the exemption list.
   - Legacy: section missing, or body case-insensitively matches `not invoked` / `skipped` / `bypassed` / `did not run`, or the verdict is neither `approved` nor `flagged` nor `blocked`.

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

   `review_pending` is a new event type; add it to `~/.claude/skills/_shared/contracts/events.md` → "Cross-agent events" with handler: "Surface in next status output. Banner: `⚠️ Review pending: <task-id> merged without Argus. Run \`/argus <task-id>\` before user verification.`"

8. Mark the debrief as processed. Post-migration: flip `state: emitted → ingested` on the debrief YAML (Edit the file in place — single-field mutation, no schema change) and append an `ingested_at` marker in the task's `history:` when the debrief has a parent task. Then emit a `debrief_ingested` event:
   ```json
   {"ts":"…","agent":"chanakya","event":"debrief_ingested","task":"<task-id-or-empty>","data":{"debrief_id":"<uuidv7>","mode":"<task|direct-debrief>","follow_ups_minted":<N>}}
   ```
   For direct-debriefs (`task_id: null`), the event's `task` field is the empty string and the `ingested_at` task-history step is skipped. Legacy fallback still moves the markdown debrief to `chanakya-inbox/processed/`. Leave `*-tests.md` in place.
9. Report: "Processed T001 — done, 2 follow-ups briefed (T014, T015). Build debt: 7/12. Unit test debt: 3/8. UI test debt: 2/6. Review pending: none." (or `Review pending: T001` when detected.) For a direct-debrief, replace the task-id with `<debrief-id[:8]>` and drop the dashboard deltas: "Ingested direct-debrief `e7756f35`, 2 follow-ups minted (T266, T267)."

### 0A.5 — Regenerate index

If any debrief was processed in 0A (task-mode or direct-debrief), run `scripts/rebuild-index.sh` once at the end of the batch. Skipping this leaves `plans/index.yaml` stale — downstream readers (`query-plans.sh`, snapshots) silently serve outdated rows. Idempotent; always safe to run.

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

Handle release-type debriefs (both TestFlight and App Store channels). Post-migration: Achilles's push-tf / app-store modes now write **two** artifacts per release — the release artifact itself at `plans/releases/<release-id>.yaml` (schema: `_shared/schemas/release.md`, `release@1.0.0`) and a release-mode debrief at `plans/debriefs/<debrief-id>.yaml` referencing the release via `links` in the debrief body / structured `key_learnings`. Legacy fallback reads the markdown debriefs `tf-*-debrief.md` (`Type: testflight-release`) and `release-*-debrief.md` (`Type: appstore-release`) from the inbox.

1. Read the release artifact (`plans/releases/<release-id>.yaml`) and its paired debrief. Extract `build_number`, `version`, `channel`, `tag`, `commit_sha`, and the `tasks[]` array. Legacy fallback parses `Build number`, `Version`, `Distribution`, `Git tag`, `HEAD`, and the `Covers:` task list from the markdown debrief header.
2. **Back-reference maintenance per §2.2 of the Phase 2.6 plan.** For each task-id in `release.tasks[]`, update the corresponding `plans/tasks/<task-id>.yaml` to set `links.release = <release-id>` (if null) and bump `updated_at`. This is the writer-maintains-counterparty invariant; the plans-index validator enforces bidirectional consistency.
3. **Emit `release_state_changed`** per `_shared/state-machines/release-lifecycle.md` when the release's observed state (from the debrief) differs from the artifact's current state. Release-state transitions fire on submission, in-review, released, etc.; see the state machine doc for the transition table.
4. **Phase 2.6 transition note:** also add a row to `## Release Log` in `chanakya-master.md` (legacy surface) with Build / Version / Type / Date / Tag / HEAD / Tasks Included — and tag each covered task's `Released in:` field (`TF-<BUILD_NUMBER>` / `AS-<BUILD_NUMBER>`, comma-separated on multi-release tasks). Cutover removes the legacy Release Log write at Commit H — the `plans/releases/` directory becomes the single source of truth.
5. Mark the debrief as processed (YAML: set the task-linkage `history` entry; legacy: move `tf-*-debrief.md` / `release-*-debrief.md` to `chanakya-inbox/processed/`). Regenerate `plans/index.yaml` via `scripts/rebuild-index.sh`.
6. Report: "Processed TestFlight release 3031 — 5 tasks tagged (T015, T016, T017, T018, T019)."
7. **Auto-trigger Slack sync.** After processing a TestFlight release debrief:
   a. Read the project memory file `project_slack_list_sync.md` to check if a Slack list is configured.
   b. If yes, automatically run Sync-Slack mode (Steps 1–7) with `--build <BUILD_NUMBER>` from the debrief.
   c. **Before writing to Slack (Step 6),** present the summary table to the user and ask: "Sync these updates to the Slack bug list? (y/n)".
   d. On confirmation, write. On rejection, skip the write but keep the computed data for manual review.
   e. This is NOT a suggestion — Chanakya proactively runs the sync computation. The only user gate is the write confirmation.

### 0B3 — App Store submission watcher (if any)

Post-migration the authoritative watcher state lives in each `plans/releases/<release-id>.yaml` under `asc_metadata` (per `_shared/schemas/release.md`); `scripts/appstore-watch.sh` reads and writes that block directly. Phase 2.6 keeps the legacy `~/.dev-studio/<project>/.runtime/state/pending-appstore-review.json` marker as a transition bridge — the migration step at Commit H promotes marker JSON into the release artifact's `asc_metadata` and retires the marker file.

If either surface indicates a pending review, invoke `bash scripts/appstore-watch.sh` (best-effort; swallow non-zero exit). The script is idempotent and self-gated on `asc_metadata.next_check_at` (or the legacy marker's `next_check_at`), so most calls exit in <50ms without an API call. It piggybacks every `/chanakya` sweep (`status`, `brief`, `ship`, `auto-sweep` tick, etc.) — no separate trigger is needed, and no `--away`/`--auto-sweep` is required.

On terminal App Store state (`pending-developer-release` / `released`, per the state machine at `_shared/state-machines/release-lifecycle.md`), the script publishes the draft release, posts a threaded Slack reply on the original `#releases` post, updates `plans/releases/<release-id>.yaml` state + `released_at`, and emits `release_state_changed` + `appstore_released`. Partial-finalize failures are handled idempotently via flags inside `asc_metadata`, so the next sweep only retries the unfinished step.

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

Read new events from today's event log since the last offset via `scripts/read-events.sh` (the canonical reader primitive per `_shared/contracts/event-emission.md`). Schema and offset protocol: `_shared/contracts/events.md`.

Post-migration canonical path: `~/.dev-studio/<project>/events/<YYYY-MM-DD>.jsonl` (day-partitioned, single source of truth per Phase 2.6 plan §3.2). The `scripts/read-events.sh` wrapper resolves the project root via `scripts/lib-paths.sh` — consumers never hardcode the path. Offset tracking uses the same reader API.

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

4. Update offset via `scripts/read-events.sh --checkpoint` (wraps the seek-to-EOF + offset-write atomically per `_shared/contracts/event-emission.md`).

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

## Cross-cutting

Debt counter rules, banners, and brief-mode refusal: see `_shared/rules/debt-tracking.md`.
Principles (including Task Status Lifecycle and session-completion event): `_shared/patterns/chanakya-principles.md`.
PRD-delta sub-command (`/chanakya review`): see `modes/review.md`.
