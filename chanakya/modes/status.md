---
name: Chanakya Status
description: Default mode. Renders master-plan summary, git state, blockers, push queue, test-flow round status, and release status.
type: mode-pack
snapshots: [briefs.json, debt.json, events-tail.json]
budget_tokens: 3000
---

# Mode: Status

Default Chanakya mode (no args). Consumes `snapshots/briefs.json` for the task table (falls back to parsing `chanakya-master.md` directly if `generated_at` is null or the snapshot is stale — status mode tolerates up to 1 hour of snapshot staleness), `snapshots/debt.json` for the debt banners (fallback: read the master plan's debt block), and `snapshots/events-tail.json` for recent activity (fallback: read today's `events/<date>.jsonl`).

## Step 1 — Read master plan and display summary

Read `~/.dev-studio/<project>/plans/chanakya-master.md` and render a table:

```
| ID   | Title                  | Priority | Status      | Complexity | Branch          |
|------|------------------------|----------|-------------|------------|-----------------|
| T001 | Export flow            | P0       | verified    | L          | —               |
| T002 | FAB redesign           | P1       | done        | M          | —               |
| T003 | HEIF encoder           | P1       | in-progress | S          | achilles/T003   |
```

Flag `done` tasks (awaiting user verification) so the user can run `/chanakya test-manifest` to consolidate them.

## Step 2 — Check git state (if tasks are in-progress)

For in-progress tasks with branches:
- `git log --oneline -3 <branch>` for recent activity
- Flag stale tasks (in-progress but no commits in 24+ hours)

## Step 3 — Surface blockers

Identify tasks blocked by dependencies. Highlight them. Surface `done` tasks awaiting verification.

## Step 3A — Surface push queue and recent events

Read `~/.dev-studio/<project>/.runtime/state/push-queue.jsonl` (if it exists; resolve via `scripts/lib-paths.sh resolve_push_queue`). Show any entries not yet marked displayed:

```
Pending notifications:
- [2026-04-18 14:32] argus: review_blocked — T001: secrets found in FilterApplier.swift:42
- [2026-04-18 15:01] achilles: merge_conflict — T003: branch left intact
```

Also read the most recent 10 events from today's event log and summarize agent activity:
> "Recent activity: Argus reviewed T001 (flagged, 3 findings), T002 merged at 14:45."

Mark displayed push queue entries after showing them.

## Step 3B — Test-flow round status

Scan `~/.dev-studio/<project>/plans/user-testing-rounds/` for existing round files:
- Report total rounds and when the latest was generated (from the `Generated:` header).
- If the latest round has unchecked cases (some `[ ] pass` remaining), report: "Round N is partially completed (K/M cases checked)."
- If the latest round is fully completed (all cases checked), report: "Round N completed — consider `--promote` to feed into review-feedback, or generate a new round."

## Step 3C — Release status

Read the `## Release Log` from the master plan:
- Report the latest TestFlight and App Store releases (build number, version, date).
- Count tasks with status `done` or `verified` whose `Released in:` field does NOT contain a `TF-` entry — these have merged since the last TestFlight build.
- If the count is > 0, suggest: "N tasks merged since last TestFlight (build <LAST_BUILD>). Run `/achilles push-tf` when ready."

Example output:
> "Latest TestFlight: build 3031 (v26.3.1, 2026-04-16). Latest App Store: build 3028 (v26.2.0, 2026-04-10). 3 tasks merged since last TestFlight — consider `/achilles push-tf`."

## Step 4 — Suggest next action

When `done` tasks exist awaiting verification, suggest both paths:

"T004 and T006 are `done` awaiting manual verification:
- `/chanakya test-manifest` — per-task verification checklist (feeds into `review-feedback`)
- `/chanakya test-flow` — single-sitting walkthrough ordered by user journey (N rounds exist, latest: round M)"

## Cross-cutting

Debt banners fire on every mode entry — see `_shared/debt-tracking.md`. Session-completion event emission and principles: `_shared/chanakya-principles.md`.
