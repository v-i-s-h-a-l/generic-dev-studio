---
name: Achilles Group
description: Composite group mode (`/achilles group <task-id>`). Executes the implementation task, then auto-continues with its test sub-tasks sequentially — all in one session. Phased: unit → integration → UI. Bails at the first unrecoverable failure with a partial debrief.
type: mode-pack
snapshots: []
budget_tokens: 1500
---

# Composite: Group Mode (`/achilles group <task-id>`)

Execute an implementation task and then automatically continue with its test sub-tasks — all in one session, no manual intervention between phases.

Each phase runs the standard task-mode pipeline. This mode is an orchestrator: it sequences task-mode invocations and rolls up a group-level summary at the end.

## Steps

1. **Resolve the group.** Read the master plan. Find the task and all sub-tasks with the same `Group:` value. Sort: implementation first, then test-unit, test-integration, test-ui.
2. **Validate.** The implementation task must be `briefed` (or `pending` with a brief available). Test sub-tasks must exist and be `pending` or `briefed`. If the implementation is already `done`, skip to the test sub-tasks.
3. **Phase 1 — Implementation.** Run the standard task-mode pipeline (Steps 1–10) for the implementation task. If it fails at any step, stop the entire group and report.
4. **Phase 2 — Test sub-tasks.** After the implementation merges successfully, execute each test sub-task sequentially through the same pipeline:
   - Unit tests first (fastest feedback loop)
   - Integration tests next
   - UI tests last (slowest, depends on accessibility IDs from impl)
   Each sub-task gets its own worktree, own build gate, own debrief. If a test sub-task fails (tests don't pass), stop and report — don't continue to the next test type.
5. **Debrief summary.** After all phases complete, print a group summary:
   > "**Group T015 complete.** Implementation merged (4 commits). Unit tests: 18 passing. UI tests: 8 passing. All debriefs dropped for Chanakya."
6. **Step 11 (follow-up surface)** runs once for the whole group, not per sub-task.

**Bail-out at any phase:** If you can't resolve a test failure after one attempt, stop, debrief what's done, and report: "Group T015 partially complete. Implementation and unit tests done. UI tests failed — see debrief."
