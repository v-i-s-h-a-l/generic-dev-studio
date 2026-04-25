---
name: Studio Janitor
description: Cross-project janitor — fans out sweep-janitor + fleet-cleanup across every project under ~/.dev-studio/. Reports counts/bytes per project. Default is dry-run; --yes actually deletes.
type: mode-pack
budget_tokens: 350
snapshots: []
reads:
  - ~/.dev-studio/*/  (project roots, via list_fleet_projects)
  - ~/.dev-studio/.runtime/derived-data/  (machine-global)
writes:
  - none in default (dry-run); --yes deletes leftover artifacts only
---

# Mode: Janitor (Studio)

Cross-project sweep of stale artifacts. Wraps two scripts that already exist — this mode is the dispatch surface, not new logic.

| Pass | Script | Targets |
|---|---|---|
| Per-project sweep | `scripts/sweep-janitor.sh --all-projects all` | Worktrees, feedback assets, orphan assets, scaling alerts, **and the gap-#31 local-debt pass** (merged worktrees, orphan DerivedData, dead-pid xcodebuild locks). |
| Per-project fleet | `scripts/fleet-cleanup.sh --all-projects` | Stale `.lock` dirs, dead `busy` markers, old `done/` entries, oversized `worker.log` rotation. |

Both scripts already implement `--all-projects`; this mode just orchestrates them and aggregates the report.

## Step 1 — Run dry-run by default

```bash
scripts/sweep-janitor.sh --dry-run --all-projects all
scripts/fleet-cleanup.sh --dry-run --all-projects
```

Aggregate the per-project counts into one summary table: project, archived count, freed bytes. Surface the largest reclaimable totals first so the user can decide whether to apply.

## Step 2 — Apply only when asked

`--yes` (or the user says "go ahead", "apply", "actually delete"):

```bash
scripts/sweep-janitor.sh --all-projects all
scripts/fleet-cleanup.sh --all-projects
```

Re-emit the same aggregate after the apply pass, with a final `cleanup_completed` count per project. The underlying scripts emit one `cleanup_completed` event per project; this mode emits no new event names.

## Step 3 — Report

| Section | Content |
|---|---|
| Summary | One line per project: `<project>: N archived, M MB freed`. |
| Hot spots | Any project with > 1 GB reclaimable, called out. |
| No-ops | Projects that swept clean (zero-row), one-line each so the user sees the negative space. |

Stop after report. No follow-up suggestion — the user runs apply when they want.

## Intent detection

Studio router dispatches here for:
- `/studio janitor` (explicit invocation)
- "clean up the studio", "what's reclaimable across projects", "sweep all projects"

For **single-project** sweeps, route to `/chanakya janitor` instead — it covers the same shape but scoped to the active project.

The **node-side** counterpart (unattended remote-worker cleanup via launchd / SSH) is tracked under issue #152 in the `phase-2.7-epic` cluster. Out of scope for this mode.

## Never

- Do not delete without `--yes` — dry-run is the safe default. The user's "minimal-intervention" rule still applies; structural confirmation via flag, not interactive prompt.
- Do not invent new event names. The two underlying scripts own `cleanup_completed`.
- Do not write outside `~/.dev-studio/**`. The two scripts already prefix-check; do not add paths that bypass that check.
- Do not auto-schedule on SessionStart. #152 owns the scheduled path; this mode is manual invocation only (avoid the failure mode #31 escalated from).
