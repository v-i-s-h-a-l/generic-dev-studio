---
name: Chanakya Compact
description: Archive verified tasks, regenerate Dashboard + Module Index + Blocked list, trim changelog, optionally sweep artifacts. Includes implicit feedback-archive + index regeneration.
type: mode-pack
snapshots: [briefs.json]
budget_tokens: 3500
reads:
  - plans/index.yaml                               # post-migration task + debrief index for archival eligibility
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/debriefs/*.yaml                          # post-migration debrief artifacts for key-learnings rollup
  - plans/feedback/*.yaml                          # feedback archive-eligibility pass
  - plans/rounds/*.yaml                            # round archival
  - plans/chanakya-master.md                       # legacy master plan (slim post-compact)
  - plans/chanakya-archive.md                      # legacy archive
  - plans/chanakya-changelog.md                    # legacy changelog
  - plans/chanakya-inbox/processed/<task-id>-debrief.md  # legacy debrief source until Commit H
  - feedback/active.md                             # legacy active-list feed
  - feedback/archive/**/*.md                       # legacy archive
  - events/<date>.jsonl                            # budget-report + cleanup data via scripts/read-events.sh
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
writes:
  - plans/tasks/<task-id>.yaml                     # state transitions to archived (per _shared/state-machines/task-lifecycle.md)
  - plans/feedback/<feedback-id>.yaml              # state transitions to archived (per _shared/state-machines/feedback-lifecycle.md)
  - plans/rounds/<round-id>.yaml                   # state transitions to archived
  - archive/2026-pre-2.6/<task-id>.yaml            # post-migration archival sink (one file per artifact kind)
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh after artifact writes
  - plans/chanakya-master.md                       # legacy master-plan slim + Dashboard block
  - plans/chanakya-archive.md                      # legacy archive append
  - plans/chanakya-changelog.md                    # legacy changelog trim
  - feedback/active.md                             # legacy prune
  - feedback/archive/build-<N>.md                  # legacy archive append
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Compact (`/chanakya compact [--dry-run] [--sweep-artifacts] [--auto-compact]`)

Archive verified tasks, regenerate the dashboard and module index, and trim the master plan to actionable items only. Keeps the plan under ~500 lines while preserving full history in the archive.

Snapshots: `snapshots/briefs.json` is consulted for the archive-eligibility pass (5-min freshness; stale or null → full master-plan parse). This mode is a producer for the briefs snapshot on completion — callers should run `scripts/chanakya-snap.sh briefs` after compact finishes.

`--sweep-artifacts` (default on) also runs the artifact sweep: rotate event logs, prune old archives, clean stale markers, remove orphaned xcresult bundles and DerivedData, and clean gitignored Playwright MCP telemetry (`.playwright-mcp/`) via `git clean -fdX` (tracked files never touched). Pass `--no-sweep-artifacts` to skip. Full spec: `~/.claude/skills/_shared/rules/cleanup-policy.md`.

`--auto-compact` prints cron setup instructions for nightly 03:00 local compact runs. Does not configure cron itself in v1. See `~/.claude/skills/_shared/rules/cleanup-policy.md`.

## File Structure

```
chanakya-master.md          ← slim: Dashboard + debt headers + active tasks only
chanakya-archive.md         ← full history: verified/done task blocks
chanakya-changelog.md       ← session changelog entries older than 7 days
```

## Steps

1. **Read master plan.** Parse all tasks with their statuses.

2. **Identify archivable tasks.** A task is archivable if:
   - Status is `verified`, OR
   - Status is `done` AND type is `audit`, `investigation`, `build-check`, `test-run`, `test infrastructure`, or `direct (user-run)`, OR
   - Status is `done` AND has been `done` for >7 days with no pending verification task referencing it as `Source:`
   
   Do NOT archive:
   - `done` tasks with open verification follow-ups (manual verification pending)
   - `pending`, `briefed`, `in-progress`, `needs-review` tasks
   - Tasks with `Source:` pointing to a non-archived parent (keep them together)

3. **Transition tasks to `archived` and write archival sink.** Post-migration, for each archivable task: transition `plans/tasks/<task-id>.yaml` state `verified → archived` per `_shared/state-machines/task-lifecycle.md`, append the `history:` entry, bump `updated_at`, and emit `task_state_changed` via `scripts/write-event.sh`. The task YAML stays in place (archived is a terminal state in the live ledger, not a separate directory — per-artifact CHANGELOG in `_shared/schemas/task.md` and the relational index handle querying). Archive-as-archive policy lives in `_shared/rules/cleanup-policy.md` — for 2.6, keep artifacts in `plans/tasks/` and let the `state` field drive archival visibility.

   **Phase 2.6 transition note:** continue to move the legacy task block from `chanakya-master.md` to `chanakya-archive.md`, trimming Notes to max 5 lines (preserve first 3 + last 2 if longer). Also move any manual-verification child tasks (type `direct (user-run)`) whose parent is being archived. Cutover removes the legacy master/archive writes at Commit H.

4. **Convert remaining done tasks to compact rows.** Tasks that are `done` but NOT archived (awaiting verification) get their full block preserved. But XS/direct tasks that have ≤3 lines of Notes can be converted to a compact table row format in a `## Done (Awaiting Verification)` table.

5. **Regenerate Dashboard.** Write/update the `## Dashboard` block at the top of master plan:
   ```markdown
   ## Dashboard
   - Active: N (X briefed, Y pending, Z in-progress)
   - Done (awaiting verification): M
   - Verified this cycle: V
   - Total shipped: S (in archive)
   - Build debt: C/12 | Unit test debt: U/8 | UI test debt: I/6
   - Latest TF: XXXX (branch) | Latest App Store: YYYY
   - Open blockers: <list tasks blocked on external input>
   - Stale: <tasks pending/briefed >72h with no activity>
   ```

6. **Regenerate Module Index.** Write/update `## Module Index`:
   ```markdown
   ## Module Index
   - **Filter:** T023, T081, T169 (3 active) | 12 archived
   - **Texture:** T130 (1 pending) | 8 archived
   - **Crop:** — (0 active) | 9 archived
   ...
   ```
   Derive module from: task title keywords, debrief `## Files Changed` directory, Skills field.

7. **Regenerate Blocked on External Input.** Scan all active tasks for blockers:
   ```markdown
   ## Blocked on External Input
   | Task | Waiting on | Who | Since |
   |------|-----------|-----|-------|
   | T130 | Which blend mode? | daksh@ | 2026-04-16 |
   ```

8. **Trim changelog.** Move entries older than 7 days to `chanakya-changelog.md`. Keep only recent entries in master.

9. **Regenerate Parallelization Map.** Only include active tasks (pending/briefed/in-progress). Remove completed tasks from the map.

10. **Artifact sweep** (when `--sweep-artifacts` is on, default): run all sweep steps from `~/.claude/skills/_shared/rules/cleanup-policy.md` (Chanakya Compact Extension section). Capture freed space and removed counts for the report.

10a. **Feedback archive + index regen.** Implicitly run `feedback-archive` (without `--notify-slack`) to move any `verified`/`wontfix` F-records to `archive/build-<N>.md`, then regenerate `feedback/reporters/<slug>.md` for every reporter seen in active + archive. Regenerate any `feedback/root-causes/<pattern>.md` whose instance list changed. These indices are always rebuilt from primary data; hand-edits are overwritten.

10b. **Budget report.** Run `scripts/budget-report.sh` (last 7 days by default). It aggregates `agent_session_completed` events from the event log and prints a per-(agent, mode) roll-up: run count, p50/p95 tokens, seed budget, p95/budget ratio, `cache_hit_rate`, `ctx_util_pct`. Include the report in the compact output below. See `~/.claude/skills/_shared/patterns/budget-telemetry.md` for the emission contract and report semantics.

11. **Report:**
    ```
    Compacted master plan:
    - Archived: 65 tasks (45 verified, 20 infra/audit)
    - Active: 15 tasks
    - Done awaiting verification: 12 tasks
    - Master plan: 2200 → 480 lines
    - Archive: 1800 lines (full history preserved)
    Swept artifacts: rotated 3 event files (gz, 42 KB), freed 6.2 GB DerivedData,
      removed 2 orphaned xcresult bundles, cleared 0 stale markers,
      deleted 14 Playwright MCP artifacts.
    ```

Emit `cleanup_completed` event with `archived` count and `freed_gb` value.

## `--dry-run`

When passed, compute all changes but don't write. Print the report showing what would move. Useful for previewing before committing.

## `--auto-compact`

Print cron setup instructions for nightly 03:00 local compact. Do not configure cron automatically. See `~/.claude/skills/_shared/rules/cleanup-policy.md` for the exact crontab line.

## Auto-trigger hooks

Compact runs automatically when:
- `review-feedback` marks ≥3 tasks `verified` in one pass
- `test-flow --promote` marks tasks verified
- Master plan exceeds 1500 lines during an inbox sweep

On auto-trigger, run compact immediately (non-destructive — `--dry-run` is available as a preview). Report what was archived.

## Master Plan Format (after compaction)

Post-compaction, the master plan gains a `## Dashboard`, `## Module Index`, and `## Blocked on External Input` block at the top, active tasks only in `## Active Tasks`, done-awaiting-verification in `## Done (Awaiting Verification)` (full blocks for M/L, compact table rows for XS/S), and a trimmed `## Changelog` (last 7 days only — older entries in `chanakya-changelog.md`).

Full schema: `~/.claude/skills/_shared/schemas/master-plan.md`.

## Post-Feature Wrap-Up

When ALL tasks for a feature are `verified` (check after every inbox sweep and after every `review-feedback`):

1. Read all debriefs for this feature's tasks. Post-migration: resolve each task's `links.debrief` to `plans/debriefs/<debrief-id>.yaml` and read the structured `key_learnings` / `decisions` / `follow_ups` fields directly. Legacy fallback: walk `chanakya-inbox/processed/` for `<task-id>-debrief.md` files during the Phase 2.6 transition.
2. Compile **Key Learnings** from all debriefs into a summary
3. Write a feature retrospective to project memory:
   - Path: `~/.claude/projects/-Users-vishalsingh-Documents-Turnip-gg-turnip-ios/memory/project_<feature_slug>.md`
   - Format: standard memory frontmatter (name, description, type: project)
   - Content: feature summary, key decisions made, gotchas discovered, architectural patterns established
   - *Note:* this path is under `~/.claude/` and may trigger a one-time self-mod permission prompt. Accept once per feature.
4. Update `MEMORY.md` index with a pointer to the new memory file
5. Tell the user: "Feature complete. Retrospective saved to project memory. Key learnings: [bullet summary]."
