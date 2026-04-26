---
name: Chanakya Verify
description: Guided single-sitting verification flow. Chains test-flow generation, user testing, then promotes + applies feedback.
type: mode-pack
schema_version: 1
snapshots: []
budget_tokens: 1500
reads:
  - plans/index.yaml                               # post-migration task + round index
  - plans/rounds/*.yaml                            # post-migration round artifacts (schema: _shared/schemas/round.md)
  - plans/reviews/*.yaml                           # post-migration review artifacts (schema: _shared/schemas/review.md)
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
writes: []  # verify is a pure orchestrator — all writes flow through the sub-modes it invokes (tests, feedback, intake)
---

# Composite: Verify (`/chanakya verify [--round N]`)

Guided single-sitting verification flow. Chains test-flow generation, waits for the user to test, then promotes and applies feedback. Verify itself owns no writes; every artifact mutation happens inside a sub-mode (test-flow, review-feedback, intake) so the state-machine transitions and event emissions live where the writer owns the contract.

## Steps

1. **Generate test-flow.** Run Test-Flow mode (unless `--round N` points to an existing round). Test-flow emits `plans/rounds/<round-id>.yaml` (schema: `_shared/schemas/round.md`, `round@1.0.0`).
2. **Prompt the user:**
   > "Test round N generated at `<path>`. Open it in your editor, walk through on a fresh build, and come back when done. Say 'done' when finished, or 'abort' to skip."
3. **Wait for user response.** (No timeout — this is a manual testing session.)
4. **On 'done':** Read `plans/rounds/<round-id>.yaml` — the `cases[].result` enum (`pending` | `pass` | `fail`) and `summary` object give a typed view with zero parsing.

   Check completion:
   - If every case has `result: pass` → invoke Test-Flow `--promote` to generate pre-checked `user-testing.md`, then Review-Feedback mode to transition task state to `verified` (per `_shared/state-machines/task-lifecycle.md`). Round state transitions `open → closed` when review-feedback's closure step fires. Report: "Verified N tasks. Feature wrap-up check running..."
   - If any case has `result: fail` → auto-file follow-up tasks via Intake mode with the failure notes as task descriptions. Intake mints each follow-up as a fresh `plans/tasks/<task-id>.yaml` with `state: proposed`. Report: "Filed N follow-up tasks for failures: T031, T032."
   - If any case has `result: pending` → report: "N cases untested. Continue testing or run `/chanakya verify --round N` to resume later." No writes.
5. **On 'abort':** "Verification paused. Round file preserved at `<path>`. Resume anytime with `/chanakya verify --round N`."
