---
name: Chanakya Status
description: Default mode. Renders master-plan summary, git state, blockers, push queue, test-flow round status, and release status.
type: mode-pack
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: [briefs.json, debt.json, feedback-inbox.json, events-tail.json]
budget_tokens: 1500
reads:
  - plans/index.yaml                               # post-migration task index (schema: _shared/schemas/task.md via plans-index-validator)
  - plans/tasks/*.yaml                             # post-migration per-task artifacts
  - plans/rounds/*.yaml                            # post-migration round artifacts
  - plans/releases/*.yaml                          # post-migration release artifacts
  - plans/chanakya-master.md                       # legacy fallback until Commit H
  - plans/user-testing-rounds/*.md                 # legacy fallback until Commit H
  - events/<date>.jsonl                            # canonical event log
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
  - .runtime/state/push-queue.jsonl                # push queue
writes:
  - .runtime/state/push-queue.jsonl                # marks entries displayed
---

# Mode: Status

Default Chanakya mode (no args). Mostly orchestration: scripts do the mechanical freshness + parsing work; this mode owns the judgment calls (which blockers matter, which next action to suggest).

## Step 0 — Load snapshots

```
scripts/status-load-snapshots.sh
```

Returns a JSON blob `{briefs, debt, feedback-inbox, events-tail}` where each domain is `{state: hit|stale|miss, age_s, payload}`. The script emits `snapshot_hit`/`snapshot_stale`/`snapshot_miss` events and fires detached `chanakya-snap.sh <domain>` rewarms for non-hit domains so the next invocation is warm. Freshness window is fixed at 60s per `_shared/patterns/router-pattern.md`.

For any domain whose state is not `hit`, full-load via `scripts/status-fallback-loaders.sh <briefs|debt|feedback|events-tail>` — same JSON shape the snapshot would have produced.

**Why 60s.** Short enough that a newly-merged task or ingested feedback record surfaces on the next invocation; long enough that a quick sequence of `/chanakya` calls all hit the same snapshot.

## Step 1 — Render task table

```
scripts/status-render-tasks.sh < <(briefs-payload)
```

Flag `done` tasks awaiting user verification so the user can run `/chanakya test-manifest` to consolidate them.

## Step 2 — Git state for in-progress tasks

For in-progress tasks with branches: `git log --oneline -3 <branch>` for recent activity; flag stale tasks (in-progress but no commits in 24+ hours). Pure judgment — no script.

## Step 3 — Surface blockers + push queue + feedback

1. **Blockers.** Identify tasks blocked by dependencies; highlight them. Surface `done` tasks awaiting verification.

2. **Push queue.** `scripts/push-queue.sh list` prints unread entries as JSONL. Show them, then `scripts/push-queue.sh mark-displayed <id>...` to clear. Summarize recent events from the events-tail payload: "Argus reviewed T001 (flagged, 3 findings), T002 merged at 14:45."

3. **Feedback inbox banner.** If the feedback-inbox snapshot's `total_pending > 0`:
   > "Feedback inbox: 3 pending (2 from turnip-ios, 1 from web). Run `/chanakya feedback` to triage."

4. **Rounds + releases.**
   ```
   scripts/status-domain.sh rounds
   scripts/status-domain.sh releases
   ```
   Each prints a single human-readable line. `releases` appends a `/achilles push-tf` suggestion when tasks have merged since the last TestFlight build.

## Step 4 — Suggest next action

Judgment call. When `done` tasks exist awaiting verification, suggest both paths:

"T004 and T006 are `done` awaiting manual verification:
- `/chanakya test-manifest` — per-task verification checklist (feeds into `review-feedback`)
- `/chanakya test-flow` — single-sitting walkthrough ordered by user journey (N rounds exist, latest: round M)"

## Cross-cutting

Debt banners fire on every mode entry — see `_shared/rules/debt-tracking.md`. Session-completion event emission and principles: `_shared/patterns/chanakya-principles.md`.
