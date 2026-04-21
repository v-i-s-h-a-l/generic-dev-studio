---
name: Chanakya Brief
description: Brief Generation mode and Brief-All composite. Writes self-contained Achilles briefs with Figma context, codebase context, type-aware structure. Brief-All iterates brief generation across every pending task in priority order.
type: mode-pack
snapshots: [briefs.json, debt.json]
budget_tokens: 4000
---

# Mode: Brief Generation (`/chanakya brief <task-id>`)

This is the most critical mode. The brief must be **completely self-contained** — a worker reads ONLY this file.

Snapshots: `snapshots/briefs.json` (tolerates 5-minute freshness — regenerate via `scripts/chanakya-snap.sh briefs` if older; fallback is a direct read of `chanakya-master.md`). `snapshots/debt.json` is checked on entry to refuse under block state (fallback: parse master-plan debt block directly).

## Step 1 — Read task from master plan

Load `~/.dev-studio/<project>/plans/chanakya-master.md`, find the task by ID. If the task is `direct` type, note this in the output ("T003 is a direct task — briefing anyway") and continue.

## Step 2 — File overlap detection

Check if the task's likely target files overlap with files listed in any `in-progress` task's brief. If overlap found, warn the user:

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

Write to `~/.dev-studio/<project>/plans/chanakya-tasks/<task-id>-<slug>.md`. The brief structure varies by task type:

### 6A — Implementation brief (Type: feature | bugfix | refactor | direct)

Write the brief following the template at `~/.claude/skills/_shared/contracts/brief-formats/impl-brief.md`.

The `## Testability Requirements` section must include: SOLID principles, accessibility identifiers, localization (if task touches UI strings — see `~/.claude/skills/_shared/rules/localization-rules.md` for the full ruleset), and test seams.

### 6B — Unit test brief (Type: test-unit)

Write the brief following the template at `~/.claude/skills/_shared/contracts/brief-formats/unit-test-brief.md`.

### 6C — Integration test brief (Type: test-integration)

Write the brief following the template at `~/.claude/skills/_shared/contracts/brief-formats/integration-test-brief.md`.

### 6D — UI test brief (Type: test-ui)

Write the brief following the template at `~/.claude/skills/_shared/contracts/brief-formats/ui-test-brief.md`.

## Step 7 — Update master plan

Set task status to `briefed`. Record the brief path.

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
