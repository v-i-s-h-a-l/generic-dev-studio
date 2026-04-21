---
name: Chanakya Status
description: Default mode. Renders master-plan summary, git state, blockers, push queue, test-flow round status, and release status.
type: mode-pack
snapshots: [briefs.json, debt.json, feedback-inbox.json, events-tail.json]
budget_tokens: 3000
---

# Mode: Status

Default Chanakya mode (no args). Reads four snapshots from `~/.dev-studio/<project>/.runtime/state/chanakya-snapshots/` and falls back to full-load per domain on miss/stale/corrupt. See `_shared/patterns/router-pattern.md` §Freshness and fallback for the contract.

## Step 0 — Load snapshots (freshness window: 60s)

For each of `briefs.json`, `debt.json`, `feedback-inbox.json`, `events-tail.json`:

1. Read `~/.dev-studio/<project>/.runtime/state/chanakya-snapshots/<domain>.json` (resolve the project root via `scripts/lib-paths.sh resolve_project_root_for`).
2. Parse `generated_at` (ISO-8601 UTC). Compute `age_seconds = now - generated_at`.
3. Classify:
   - **Missing file / empty / not valid JSON** → miss. Emit `snapshot_miss` with `reason=missing_file` or `corrupt`. Fall back to the full-load path for that domain only (see Step 0A–0D below).
   - **`generated_at` is null** → miss with `reason=not_generated`. Fall back.
   - **`age_seconds > 60`** → stale. Emit `snapshot_stale` with `age_seconds` and `staleness_window_seconds=60`. Fall back.
   - **`age_seconds ≤ 60`** → hit. Emit `snapshot_hit` with `domain` + `age_seconds`. Use the snapshot exclusively for that domain.
4. Event emission uses the `append_event` helper from `scripts/lib-paths.sh` (agent=`chanakya`, task=`""`).
5. At the end of Step 0, if **any** domain was stale/missing, fire `scripts/chanakya-snap.sh <domain> &` for each such domain in the background — detached, no wait — so the next invocation hits a fresh snapshot. Use `&` (single-domain) rather than `all` to keep the background cost proportional to what actually fell behind.

**Why 60s.** Status tolerates recent activity but users expect fresh numbers; a minute is short enough that a newly-merged task or ingested feedback record surfaces on the next invocation, long enough that a quick sequence of `/chanakya` calls all hit the same snapshot.

### Step 0A — Full-load fallback: briefs

Parse `~/.dev-studio/<project>/plans/chanakya-master.md` directly. Walk `### Txxx — title` blocks, extract Status / Priority / Complexity / Branch. This is the authoritative source; the snapshot is only an indirection.

### Step 0B — Full-load fallback: debt

Read the `## Build Debt`, `### Unit Test Debt`, and `### UI Test Debt` blocks from the master plan. Banner thresholds are documented in `_shared/rules/debt-tracking.md`.

### Step 0C — Full-load fallback: feedback-inbox

Walk `~/.dev-studio/generic-dev-studio/feedback-inbox/<project>/*.md` (or all scopes when running from gds itself). Count unprocessed files (exclude `processed/` subtree).

### Step 0D — Full-load fallback: events-tail

Read the last 25 lines of today's event log at `<project-memory>/events/<YYYY-MM-DD>.jsonl` (resolve via `resolve_event_log`).

## Step 1 — Render task table (from briefs snapshot or fallback)

Render a table of active tasks:

```
| ID   | Title                  | Priority | Status      | Complexity | Branch          |
|------|------------------------|----------|-------------|------------|-----------------|
| T001 | Export flow            | P0       | verified    | L          | —               |
| T002 | FAB redesign           | P1       | done        | M          | —               |
| T003 | HEIF encoder           | P1       | in-progress | S          | achilles/T003   |
```

If the snapshot was a hit, use `tasks[]` + `by_status`. If fallback, parse the master plan directly.

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

For recent events, use the events-tail snapshot (`events[]`) or fallback. Summarize agent activity:
> "Recent activity: Argus reviewed T001 (flagged, 3 findings), T002 merged at 14:45."

Mark displayed push queue entries after showing them.

## Step 3B — Feedback inbox banner

Use the feedback-inbox snapshot (`total_pending`, `by_scope`) or fallback. If `total_pending > 0`, surface a one-liner:
> "Feedback inbox: 3 pending (2 from turnip-ios, 1 from web). Run `/chanakya feedback` to triage."

## Step 3C — Test-flow round status

Scan `~/.dev-studio/<project>/plans/user-testing-rounds/` for existing round files:
- Report total rounds and when the latest was generated (from the `Generated:` header).
- If the latest round has unchecked cases (some `[ ] pass` remaining), report: "Round N is partially completed (K/M cases checked)."
- If the latest round is fully completed (all cases checked), report: "Round N completed — consider `--promote` to feed into review-feedback, or generate a new round."

## Step 3D — Release status

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

Debt banners fire on every mode entry — see `_shared/rules/debt-tracking.md`. Session-completion event emission and principles: `_shared/patterns/chanakya-principles.md`.
