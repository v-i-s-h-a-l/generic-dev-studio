---
name: Chanakya Brief
description: Brief Generation mode and Brief-All composite. Writes self-contained Achilles briefs with Figma context, codebase context, type-aware structure. Brief-All iterates brief generation across every pending task in priority order.
type: mode-pack
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: [briefs.json, debt.json]
budget_tokens: 4000
reads:
  - plans/index.yaml                               # post-migration task index
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/briefs/*.yaml                            # post-migration brief artifacts for in-progress overlap checks
  - plans/chanakya-master.md                       # legacy fallback until Commit H
  - plans/chanakya-tasks/*.md                      # legacy brief read surface until Commit H
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
writes:
  - plans/briefs/<brief-id>.yaml                   # post-migration canonical (schema: _shared/schemas/brief.md, brief@3.1.0)
  - plans/tasks/<task-id>.yaml                     # back-ref update: links.brief + state bump
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh after artifact writes
  - plans/chanakya-tasks/<task-id>-<slug>.md       # legacy markdown brief retained during Phase 2.6 transition (cutover removes at Commit H)
  - plans/chanakya-master.md                       # legacy task-status mutation until Commit H
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Brief Generation (`/chanakya brief <task-id>`)

This is the most critical mode. The brief must be **completely self-contained** — a worker reads ONLY this file.

Snapshots: `snapshots/briefs.json` (tolerates 5-minute freshness — regenerate via `scripts/chanakya-snap.sh briefs` if older; fallback is a direct read of `chanakya-master.md`). `snapshots/debt.json` is checked on entry to refuse under block state (fallback: parse master-plan debt block directly).

## Step 1 — Read task

Post-migration surface: resolve the task via `scripts/query-plans.sh --kind=task --id=<task-id>` against `plans/tasks/<task-id>.yaml` (schema: `_shared/schemas/task.md`, `task@1.0.0`). If the task is `direct` type, note this in the output ("T003 is a direct task — briefing anyway") and continue.

**Phase 2.6 transition:** if the YAML artifact is absent (migration has not run), fall back to `~/.dev-studio/<project>/plans/chanakya-master.md` and emit one `legacy_artifact_read` event so the fallback is visible. Cutover removes the legacy read at Commit H.

## Step 1A — Master-plan registration gate

Before anything else, ensure the task has a `### <legacy-task-id>` section in `chanakya-master.md`. Tasks briefed directly (without running `/chanakya intake`) otherwise dispatch and complete invisibly — when Achilles drops a debrief, the sweep has no master-plan row to update, the debrief flips `emitted → ingested`, and on every subsequent sweep the `state: emitted` filter skips it permanently. This is the "silent double-miss" the 2026-04-23 bug reports documented.

Resolve the task's `legacy_task_id` (from Step 1's task YAML). If `grep -q "^### $legacy_id " chanakya-master.md` returns non-zero, write a stub row immediately:

```bash
scripts/lib-ledger.sh  # sourced helper
legacy_master_plan_append_row "$legacy_id" "$title" "$priority" "$type" "brief:stub" "briefed"
```

The helper is idempotent — a re-brief no-ops if the section already exists. Use `brief:stub` as the `Source:` field so the row is recognizable as brief-time provenance rather than intake-time.

If `legacy_task_id` is empty (UUID-only task), skip — nothing to key the section on. Callers who want master-plan visibility must supply a legacy id.

## Step 2 — File overlap detection

Check if the task's likely target files overlap with files listed in any `in-progress` task's brief. Post-migration surface: `scripts/query-plans.sh --kind=brief --state=dispatched` enumerates the active briefs; match the union of each brief's `writes:` + `reads:` arrays against the new task's expected targets. Legacy fallback scans the brief markdown under `plans/chanakya-tasks/`. On overlap warn the user:

"T003 will touch PhotoEditorContainerView.swift, which T001 is currently modifying. Recommend waiting for T001 to finish, or coordinating on separate sections."

## Step 3 — Gather Figma context

If the task has Figma references:
1. Call `mcp__figma__get_design_context(fileKey, nodeId, prompt="generate for iOS using SwiftUI")` for each node
2. Call `mcp__figma__get_screenshot(fileKey, nodeId)` — note the screenshot path
3. Call `mcp__figma__get_variable_defs(fileKey, nodeId)` for design tokens
4. **Inline everything** into the brief — the worker must not need MCP access

If no Figma refs AND task type is `feature` or UI-related: ask "Does this task have a Figma design? Paste the URL or say 'no design'." Otherwise skip silently and continue to Step 4.

## Step 4 — Gather codebase context

Use Glob and Grep to find:
1. **Files to modify** — primary files the worker will touch
2. **Files to read** — adjacent files for context (view models, protocols, models)
3. **Patterns to follow** — find a similar existing feature and reference it
4. **Architectural constraints** — read relevant memory files from project memory
5. **Testing context** — find existing test files for the module (`*Tests.swift`, `*UITests.swift`), existing accessibility identifier enums, test helpers/utilities, and the project's test organization pattern

## Step 5 — Determine branch strategy

- Independent task: propose a new branch name (convention: `v/<feature-slug>` or `achilles/<task-id>`)
- Dependent task: note the base branch
- Include exact git commands to create the worktree (Achilles handles the actual worktree add; the brief only names conventions)

## Step 6 — Write the brief (type-aware)

Write the brief as YAML to `~/.dev-studio/<project>/plans/briefs/<brief-id>.yaml` per schema `_shared/schemas/brief.md` (`brief@3.1.0`). Mint `id` as a UUIDv7; populate `schema_version`, `task_id` (the parent task's UUIDv7), `type`, `size` (mirrors the parent task's size), `state: ready`, `created_at`/`updated_at` (RFC3339 UTC), `figma`, `reads`, `writes`, `acceptance`, `testability`, `rework_of`. The type-specific narrative — rendered from the template corresponding to the task type — goes into the `body:` multi-line string.

State transitions follow `_shared/state-machines/brief-lifecycle.md`: initial state is `ready` (`draft → ready`); dispatch flips it to `dispatched` when Achilles claims the brief.

**Phase 2.6 transition note:** also write the legacy markdown form at `~/.dev-studio/<project>/plans/chanakya-tasks/<task-id>-<slug>.md` for one cycle so in-flight consumers (direct `cat` reads from older sessions or stale worker wrappers) still see the brief. Cutover removes the legacy write at Commit H.

### 6A — Implementation brief (Type: feature | bugfix | refactor | direct)

Render the body from the template at `~/.claude/skills/_shared/contracts/brief-formats/impl-brief.md`.

The `## Testability Requirements` section (captured both as the `testability:` array field and inlined in `body:`) must include: SOLID principles, accessibility identifiers, localization (if task touches UI strings — see `~/.claude/skills/_shared/rules/localization-rules.md` for the full ruleset), and test seams.

### 6B — Unit test brief (Type: test-unit)

Render the body from the template at `~/.claude/skills/_shared/contracts/brief-formats/unit-test-brief.md`.

### 6C — Integration test brief (Type: test-integration)

Render the body from the template at `~/.claude/skills/_shared/contracts/brief-formats/integration-test-brief.md`.

### 6D — UI test brief (Type: test-ui)

Render the body from the template at `~/.claude/skills/_shared/contracts/brief-formats/ui-test-brief.md`.

## Step 7 — Update task and regenerate index

Update the parent task at `~/.dev-studio/<project>/plans/tasks/<task-id>.yaml`:

- Set `links.brief = <brief-id>` (back-reference per §2.2 of the Phase 2.6 plan — the writer that creates the link maintains the counterparty).
- Append a `history:` entry for `proposed → briefed` (or `briefed → briefed` on re-brief — treat re-brief as a same-state update with the new brief-id in `links.brief`).
- Bump `updated_at`.

Emit `brief_state_changed` (from null to `ready`) and `task_state_changed` per `_shared/contracts/events.md` via `scripts/write-event.sh`. Then regenerate `plans/index.yaml` via `scripts/rebuild-index.sh` (the pre-commit hook from Commit D handles staged artifacts; modes call it directly for non-committed writes).

**Phase 2.6 transition note:** also mutate `plans/chanakya-master.md` (set the legacy task row's status to `briefed`, record the legacy brief path) until Commit H cutover.

## Step 7A — Invalidate briefs snapshot

After the master-plan write, fire the briefs snapshot producer in the background so the next status read is fresh inside the 60-second window:

```bash
scripts/chanakya-snap.sh briefs &
```

Don't wait for it. The producer is ~50ms and idempotent; worst case the next status invocation falls back to a full-load. Why: a user who briefs a task then immediately runs `/chanakya` expects to see the new `briefed` status without a 60-second lag.

## Step 8 — Suggest next action

"T001 brief ready at chanakya-tasks/T001-export-flow.md. Next: T002 is independent and P1 — brief it with `/chanakya brief T002` or launch a worker with `/achilles T001`."

---

# Composite: Brief-All (`/chanakya brief-all`)

Brief every `pending` task in the master plan, in priority order, without asking for confirmation between each one.

## Steps

1. Read the master plan. Collect all tasks with status `pending` (exclude `direct` type — those don't need briefs).
2. If zero candidates, report: "No pending tasks to brief." Return.
3. Sort by priority (P0 first), then by task ID.
4. **Check debt gates.** If build or test debt is in `block` state, filter out implementation tasks and keep only test sub-tasks and TBUILD/TUNIT/TUI tasks. If nothing remains after filtering, report the block and return.
5. For each task, run Brief Generation mode (Steps 1–8) sequentially. Skip user confirmation between briefs — the user already approved by running `brief-all`.
6. **Invalidate once, at the end.** Skip Step 7A's per-task snapshot refresh while iterating; fire one `scripts/chanakya-snap.sh briefs &` after the loop finishes. Avoids N redundant producer runs on a batch brief.
7. Report: "Briefed N tasks: T001, T002, T003a, T004c. All ready for `/achilles`. Suggest: `/achilles ship next` to start executing."

**Guard:** If a brief fails (e.g., missing Figma context, file overlap conflict), log the failure, skip that task, and continue with the next. Report skipped tasks at the end.

## Brief formats (shared)

Implementation brief format: `~/.claude/skills/_shared/contracts/brief-formats/impl-brief.md`
Unit test brief format: `~/.claude/skills/_shared/contracts/brief-formats/unit-test-brief.md`
Integration test brief format: `~/.claude/skills/_shared/contracts/brief-formats/integration-test-brief.md`
UI test brief format: `~/.claude/skills/_shared/contracts/brief-formats/ui-test-brief.md`
TDD brief format: `~/.claude/skills/_shared/contracts/brief-formats/tdd-brief.md`

Debrief format (for the `## Debrief Instructions` section in every brief): `~/.claude/skills/_shared/contracts/debrief-format.md`
