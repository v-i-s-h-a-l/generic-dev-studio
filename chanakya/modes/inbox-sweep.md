---
name: Chanakya Inbox Sweep
description: Pre-dispatch inbox sweep procedure. Runs Steps 0A–0G before every Chanakya mode — regular task debriefs (task-mode + direct-debrief), manual-build-check debriefs, release debriefs, App Store watcher, threshold actions, stale-artifact janitor, event log processing, feedback reminders, blind-spot detection, studio-feedback ingestion. Split out of modes/review.md on 2026-04-22 so non-review invocations don't pay for PRD-delta prose they never use.
type: mode-pack
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: [debt.json, events-tail.json, feedback-inbox.json]
budget_tokens: 1500
reads:
  - plans/index.yaml
  - plans/tasks/*.yaml
  - plans/debriefs/*.yaml
  - plans/reviews/*.yaml
  - plans/releases/*.yaml
  - plans/feedback/*.yaml
  - plans/chanakya-master.md                       # legacy fallback until Commit H
  - plans/chanakya-inbox/**                        # legacy debriefs until Commit H
  - feedback/active.md
  - events/<date>.jsonl                            # via scripts/read-events.sh
writes:
  - plans/tasks/<task-id>.yaml                     # state transitions + links (via lib-ledger)
  - plans/releases/<release-id>.yaml               # release state transitions on debrief ingest
  - plans/debriefs/<debrief-id>.yaml               # emitted → ingested flip
  - plans/chanakya-master.md                       # legacy mutation until Commit H
  - plans/chanakya-inbox/processed/                # legacy debrief move destination
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Inbox Sweep (pre-dispatch Step 0)

The router always runs this before dispatching to the user's mode. Also the body of `--auto-sweep` ticks and `/chanakya sweep` (which runs Step 0 and exits). PRD-delta prose now lives in `modes/review.md`.

## Step −1 — Session Launch

First `/chanakya` invocation in a session (no `--auto-sweep`): proceed directly to Step 0. Read `chanakya_mode.md`; write `mode: at-laptop` if missing.

## Step 0 — Enumerate + ingest debriefs

Run `scripts/sweep-enumerate-debriefs.sh`. Output is tab-separated `<kind>\t<path>\t<mode>` lines. For each line, invoke `scripts/sweep-ingest.sh <kind> <path> [flags]`.

### 0A — Uniform debrief ingest (task + direct-debrief)

Debriefs from `task` mode (with `task_id` + `brief_id` set) and `direct-debrief` mode (both null; surface: `/achilles debrief`) share `debrief@2.0.2`. The script branches on `mode` + `task_id` null-state; direct-debriefs skip task-linkage and go straight to follow-up minting. Semantic linking against prior debriefs and open issues (`similar_to`, `duplicate_of`, `part_of`) is Phase 2.7 scope.

**Worker-report routing (`report_state`).** Per `_shared/contracts/worker-report.md`, every debrief carries one of four states that deterministically routes what Chanakya does next — no prose parsing:

| `report_state` | Task transition | Surface |
|---|---|---|
| `done` | `done` | Normal close; no banner |
| `done_with_concerns` | `done` | Append to status dashboard; push-queue entry if debt crosses threshold per 0C |
| `blocked` | `blocked` | Push-queue entry + banner; do not re-dispatch |
| `needs_context` | `needs_brief_rework` | Regenerate brief filling the gap named in `open_questions`; re-dispatch on next sweep once brief returns to `ready` |

Pre-2.0.2 debriefs lack `report_state`; infer per the back-compat rule in the worker-report contract (typically `done_with_concerns` as the conservative default).

**Argus-skip detection (judgment retained in this mode pack).** A debrief counts as Argus-skipped when `argus_review.status == not-invoked` (YAML) or the legacy `## Argus Review` section matches `not invoked|skipped|bypassed|did not run`. Exemptions, never flagged:

- Task type is `build-check`, `test-suite-run`, `direct (user-run)`, `documentation`, or title starts with `TBUILD-` / `TUNIT-` / `TUI-`.
- Notes explicitly say `argus: not required` (operator override).

Pass `--argus-exempt` to `sweep-ingest.sh debrief` when the task matches an exemption. The script then suppresses the `review_pending` emit; otherwise it emits:

```
⚠️ Review pending: <task-id> merged without Argus. Run `/argus <task-id>` before user verification.
```

After the loop, run `scripts/rebuild-index.sh` once if any debrief was processed — skipping it leaves `plans/index.yaml` stale.

### 0B2 — Release debrief Slack sync

After `sweep-ingest.sh release` processes a TestFlight release debrief:

1. Read project memory `project_slack_list_sync.md` for the configured list.
2. Automatically run Sync-Slack mode (Steps 1–7) with `--build <BUILD_NUMBER>`.
3. **Before the Slack write (Step 6)** present the summary table and ask: *"Sync these updates to the Slack bug list? (y/n)"*. Write on confirm; keep computed data on reject for manual review.

Chanakya proactively runs the computation. The only user gate is the write confirmation.

### 0B3 — App Store watcher piggyback

Invoke `bash scripts/appstore-watch.sh` (best-effort; swallow non-zero). The script is self-gated on `asc_metadata.next_check_at`, so most calls exit in <50ms. If the marker carries `"stuck": true`, surface inline:

```
⚠️ App Store watcher stuck on <tag> (<N> failures, last: <reason>).
```

Read the stuck state by `grep '"stuck": true'` on the marker — don't re-invoke the watcher just for status.

## Step 0C — Threshold actions

`scripts/sweep-threshold-actions.sh` reads the counter in `chanakya-master.md` §`## Build Debt` and fires: counter ≥ 6 + no open TBUILD → mint TBUILD (P1) + emit `build_debt_warned`; counter ≥ 12 → set `build_debt_blocked` state flag + emit `build_debt_blocked`. Rules: `_shared/rules/debt-tracking.md`.

## Step 0D — Stale-artifact janitor

`scripts/sweep-janitor.sh all`. Subcommands: `worktrees` (7d mtime, skips live + `.argus-running`), `feedback-assets` (30d + state=archived), `orphan-assets` (7d grace for unreferenced), `scaling-alerts` (warn@50, block@100 sets `feedback_ingest_blocked`). Honors `DRY_RUN=1`. Every delete is prefix-checked against the project root.

## Step 0E — Event handler fan-out

`scripts/sweep-process-events.sh` reads new events since the offset at `.runtime/state/events_offset` and fires:

| Event | Action |
|---|---|
| `task_completed` | `achilles-queue.sh drain` (frees worker slot). |
| `brief_failed` / `merge_conflict` / `review_blocked` / `task_awaiting_user` / `task_rescued` | Also drain — each frees a worker without emitting `task_completed`, so skipping would strand the queue. |
| `review_flagged` | Mint one follow-up task per `data.findings[]` entry (type=review-followup, P2, `source_review=<review_id>`, `finding_index=<i>`). Idempotent via source_review+finding_index marker. |
| `review_blocked` | Also push-queue append kind=`review_blocked` with the block reason. |
| `appstore_watch_stuck` | Push-queue append kind=`appstore_stuck`. |
| `dual_write_partial` | Push-queue append kind=`drift` + raw line appended to `.runtime/state/drift-log.jsonl`. |
| `test_run_failed` / `build_debt_incremented` | No direct action; surfaced in status. |

Offset update is atomic (tmp + mv).

## Step 0E2 — Feedback reminders

`scripts/sweep-feedback-reminders.sh` reads the `## Reminders` table in `feedback/active.md`; each row with `due_at` in the past emits `feedback_reminder_due` with `{reminder_body, ingest_mode_hint, due_at}` and is removed atomically. A subsequent run finds nothing (idempotent).

## Step 0E3 — Blind-spot detection

`scripts/detect-edits.sh --quiet` handles brief_edited / debrief_edited in one shot (own markers, own idempotency). Two sweep-time signals stay inline — they need in-session context no script can see:

| Signal | When | Call |
|---|---|---|
| User overrode an Argus flag | User confirms "ship anyway" on a `review_flagged` task in ship / review-feedback / intake. | `scripts/write-event.sh --agent chanakya --event review_override --task <task> --data '{"review_file":"<path>","finding_count":<n>,"reason":"<≤100 chars>"}'` — once per override, not per finding. |
| Build-debt counter incremented | After `sweep-ingest.sh` applies an `lsp-only` debrief and bumps the counter. | `scripts/write-event.sh --agent chanakya --event build_debt_incremented --task <task> --data '{"counter":"build","new_value":<n>,"trigger":"xs_skip"}'`. |

## Step 0F — Studio-feedback inbox

`scripts/ingest-feedback.sh`. The script is gated on `resolve_project == generic-dev-studio` — any other project silent-exits. Also auto-runs on SessionStart here (`.claude/settings.json`). Re-running is idempotent.

## Step 0G — Adaptive backoff (auto-sweep only)

For `--auto-sweep`, determine whether the sweep was blank (no events processed, no debriefs ingested, no reminders fired). Run `scripts/sweep-adaptive-backoff.sh <was-blank:0|1>`; it prints the next delay in seconds (900 → 1800 → 3600 → 7200, cap 7200; resets to 900 on any activity) and persists state at `.runtime/state/auto_sweep_state.md`. Reschedule, then stop.

## Cross-cutting

- Debt counter rules + banners + brief-mode refusal: `_shared/rules/debt-tracking.md`.
- Principles + session-completion event: `_shared/patterns/chanakya-principles.md`.
- PRD-delta sub-command (`/chanakya review`): `modes/review.md`.
