---
name: Chanakya Compact
description: Archive verified tasks, regenerate Dashboard + Module Index + Blocked list, trim changelog, optionally sweep artifacts. Includes implicit feedback-archive + index regeneration.
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: [briefs.json]
budget_tokens: 3500
reads:
  - plans/index.yaml                               # post-migration task + debrief index for archival eligibility
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/debriefs/*.yaml                          # post-migration debrief artifacts for key-learnings rollup
  - plans/feedback/*.yaml                          # feedback archive-eligibility pass
  - plans/rounds/*.yaml                            # round archival
  - plans/master-plan-preamble.md                  # editorial source for Dashboard/Module Index/Blocked sections (rendered by scripts/render-master-plan.sh)
  - plans/chanakya-archive.md                      # legacy archive (kept; trimmed in place)
  - plans/chanakya-changelog.md                    # legacy changelog (kept; trimmed in place)
  - feedback/active.md                             # F-id active-list feed
  - feedback/archive/**/*.md                       # F-id archive
  - events/<date>.jsonl                            # budget-report + cleanup data via scripts/read-events.sh
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
writes:
  - plans/tasks/<task-id>.yaml                     # state transitions to archived (per _shared/state-machines/task-lifecycle.md)
  - plans/feedback/<feedback-id>.yaml              # state transitions to archived (per _shared/state-machines/feedback-lifecycle.md)
  - plans/rounds/<round-id>.yaml                   # state transitions to archived
  - plans/master-plan-preamble.md                  # Dashboard/Module Index/Blocked regen (consumed by render-master-plan.sh)
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh after artifact writes
  - plans/chanakya-archive.md                      # archive append
  - plans/chanakya-changelog.md                    # changelog trim
  - feedback/active.md                             # F-id prune
  - feedback/archive/build-<N>.md                  # F-id archive append
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Compact (`/chanakya compact [--dry-run] [--sweep-artifacts] [--auto-compact]`)

Archive verified tasks and regenerate the editorial preamble (Dashboard, Module Index, Blocked-on-External-Input). `chanakya-master.md` is a Shape B projection rendered by `scripts/render-master-plan.sh` from `plans/master-plan-preamble.md` + `plans/build-debt.yaml` + `plans/index.yaml` + `plans/tasks/*.yaml` + `plans/releases/*.yaml`; compact updates the preamble and lets the projector run.

Snapshots: `snapshots/briefs.json` is consulted for the archive-eligibility pass (5-min freshness; stale or null → `scripts/query-plans.sh --kind=task`). This mode is a producer for the briefs snapshot on completion — callers should run `scripts/chanakya-snap.sh briefs` after compact finishes.

`--sweep-artifacts` (default on) also runs the artifact sweep: rotate event logs, prune old archives, clean stale markers, remove orphaned xcresult bundles and DerivedData, and clean gitignored Playwright MCP telemetry (`.playwright-mcp/`) via `git clean -fdX` (tracked files never touched). Pass `--no-sweep-artifacts` to skip. Full spec: `~/.claude/skills/_shared/rules/cleanup-policy.md`.

`--auto-compact` prints cron setup instructions for nightly 03:00 local compact runs. Does not configure cron itself in v1. See `~/.claude/skills/_shared/rules/cleanup-policy.md`.

## File Structure

```
master-plan-preamble.md     ← editorial source: Dashboard + Module Index + Blocked
chanakya-master.md          ← rendered projection (output of render-master-plan.sh)
chanakya-archive.md         ← full history: verified/done task blocks
chanakya-changelog.md       ← session changelog entries older than 7 days
```

## Steps

1. **Enumerate active tasks.** `scripts/query-plans.sh --kind=task` for state.

2. **Identify archivable tasks.** A task is archivable if:
   - Status is `verified`, OR
   - Status is `done` AND type is `audit`, `investigation`, `build-check`, `test-run`, `test infrastructure`, or `direct (user-run)`, OR
   - Status is `done` AND has been `done` for >7 days with no pending verification task referencing it as `Source:`
   
   Do NOT archive:
   - `done` tasks with open verification follow-ups (manual verification pending)
   - `pending`, `briefed`, `in-progress`, `needs-review` tasks
   - Tasks with `Source:` pointing to a non-archived parent (keep them together)

3. **Transition tasks to `archived`.** For each archivable task: transition `plans/tasks/<task-id>.yaml` state `verified → archived` via `lib-ledger.transition_task_state` (appends `history:`, bumps `updated_at`, emits `task_state_changed`). The task YAML stays in place — archived is a terminal state in the live ledger, not a separate directory; the relational index drives archival visibility. Archive-as-archive policy: `_shared/rules/cleanup-policy.md`.

   For the rendered projection, the archive section of `chanakya-archive.md` is appended in place during this step (legacy editorial surface — kept until a YAML-shaped archive viewer ships). Trim Notes to max 5 lines (preserve first 3 + last 2 if longer). Also move any manual-verification child tasks (type `direct (user-run)`) whose parent is being archived.

4. **Convert remaining done tasks to compact rows.** Tasks that are `done` but NOT archived (awaiting verification) get their full block preserved. But XS/direct tasks that have ≤3 lines of Notes can be converted to a compact table row format in a `## Done (Awaiting Verification)` table.

5. **Regenerate Dashboard.** Write/update the `## Dashboard` block in `plans/master-plan-preamble.md` (rendered by `scripts/render-master-plan.sh` into `chanakya-master.md`):
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

6. **Regenerate Module Index.** Write/update `## Module Index` in the preamble:
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

8. **Trim changelog.** Move entries older than 7 days to `chanakya-changelog.md`. Keep only recent entries in the preamble.

9. **Regenerate Parallelization Map.** Only include active tasks (pending/briefed/in-progress). Remove completed tasks from the map.

10. **Artifact sweep** (when `--sweep-artifacts` is on, default): run all sweep steps from `~/.claude/skills/_shared/rules/cleanup-policy.md` (Chanakya Compact Extension section). Capture freed space and removed counts for the report.

10a. **Feedback archive + index regen.** Implicitly run `feedback-archive` (without `--notify-slack`) to move any `verified`/`wontfix` F-records to `archive/build-<N>.md`, then regenerate `feedback/reporters/<slug>.md` for every reporter seen in active + archive. Regenerate any `feedback/root-causes/<pattern>.md` whose instance list changed. These indices are always rebuilt from primary data; hand-edits are overwritten.

10b. **Budget report.** Run `scripts/budget-report.sh` (last 7 days by default). It aggregates `agent_session_completed` events from the event log and prints a per-(agent, mode) roll-up: run count, p50/p95 tokens, seed budget, p95/budget ratio, `cache_hit_rate`, `ctx_util_pct`. Include the report in the compact output below. See `~/.claude/skills/_shared/patterns/budget-telemetry.md` for the emission contract and report semantics.

11. **Report:**
    ```
    Compacted plan state:
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
- The rendered `chanakya-master.md` exceeds 1500 lines during an inbox sweep

On auto-trigger, run compact immediately (non-destructive — `--dry-run` is available as a preview). Report what was archived.

## Plan format (after compaction)

Post-compaction, the preamble carries `## Dashboard`, `## Module Index`, and `## Blocked on External Input`. The rendered `chanakya-master.md` then carries those plus `## Active Tasks`, `## Done (Awaiting Verification)` (full blocks for M/L, compact table rows for XS/S), and a trimmed `## Changelog` (last 7 days; older entries spill to `chanakya-changelog.md`).

## Post-Feature Wrap-Up

When ALL tasks for a feature are `verified` (check after every inbox sweep and after every `review-feedback`):

1. Read all debriefs for this feature's tasks: resolve each task's `links.debrief` to `plans/debriefs/<debrief-id>.yaml` and read the structured `key_learnings` / `decisions` / `follow_ups` fields directly.
2. Compile **Key Learnings** from all debriefs into a summary
3. Write a feature retrospective to project memory:
   - Path: `~/.claude/projects/-Users-vishalsingh-Documents-Turnip-gg-turnip-ios/memory/project_<feature_slug>.md`
   - Format: standard memory frontmatter (name, description, type: project)
   - Content: feature summary, key decisions made, gotchas discovered, architectural patterns established
   - *Note:* this path is under `~/.claude/` and may trigger a one-time self-mod permission prompt. Accept once per feature.
4. Update `MEMORY.md` index with a pointer to the new memory file
5. Tell the user: "Feature complete. Retrospective saved to project memory. Key learnings: [bullet summary]."
