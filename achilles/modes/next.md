---
name: Achilles Next
description: Composite next mode (`/achilles next [N]`). Picks and executes the highest-priority ready task without the user specifying a task ID. With N>1, prints a dispatch plan for other tabs.
type: mode-pack
snapshots: []
budget_tokens: 1000
reads: []
writes: []
---

# Composite: Next Mode (`/achilles next [N]`)

Pick and execute the highest-priority ready task without the user specifying a task ID.

Delegates execution to the task-mode pipeline; this mode is only the picker + dispatcher.

## Steps

1. **Read the master plan.** Find all tasks with status `briefed` (ready for execution). Sort by:
   - Priority (P0 first)
   - Type preference: TBUILD/TUNIT/TUI tasks first (debt reduction), then test sub-tasks whose parent is `done`, then implementation tasks
   - Task ID (lower first, as tiebreaker)
2. **If N is omitted (or N=1):** Pick the top task. Print: "Next up: T003 — Share sheet integration (P1, S). Executing..." then run the standard task-mode pipeline immediately.
3. **If N > 1:** Pick the top N tasks. Print a dispatch plan (same phased format as Chanakya's `ship`):
   > "Top 3 ready tasks:
   >   Tab 1: /achilles T003 — Share sheet (P1, S)  ← executing now
   >   Tab 2: /achilles T015a — Unit tests: filter presets (P1, M)
   >   Tab 3: /achilles T018c — UI tests: crop flow (P1, M)"
   Execute the first task in this session immediately. Print the remaining commands for the user to run in other tabs (Achilles cannot spawn sibling sessions).
4. **If no tasks are `briefed`:** Check for `pending` tasks and suggest: "No briefed tasks. Run `/chanakya brief-all` or `/chanakya ship next` to brief and dispatch."
