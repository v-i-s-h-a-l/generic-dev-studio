---
name: Chanakya Verify
description: Guided single-sitting verification flow. Chains test-flow generation, user testing, then promotes + applies feedback.
type: mode-pack
snapshots: []
budget_tokens: 1500
reads: []
writes: []
---

# Composite: Verify (`/chanakya verify [--round N]`)

Guided single-sitting verification flow. Chains test-flow generation, waits for the user to test, then promotes and applies feedback.

## Steps

1. **Generate test-flow.** Run Test-Flow mode (unless `--round N` points to an existing round). This produces the walkthrough file.
2. **Prompt the user:**
   > "Test round N generated at `<path>`. Open it in your editor, walk through on a fresh build, and come back when done. Say 'done' when finished, or 'abort' to skip."
3. **Wait for user response.** (No timeout — this is a manual testing session.)
4. **On 'done':** Read the round file. Check completion:
   - If all cases have `[x] pass` → run `--promote` to generate pre-checked `user-testing.md`, then run Review-Feedback mode to mark tasks `verified`. Report: "Verified N tasks. Feature wrap-up check running..."
   - If any cases have `[x] fail` → auto-file follow-up tasks via Intake mode with the failure notes as task descriptions. Report: "Filed N follow-up tasks for failures: T031, T032."
   - If cases are unchecked → report: "N cases untested. Continue testing or run `/chanakya verify --round N` to resume later."
5. **On 'abort':** "Verification paused. Round file preserved at `<path>`. Resume anytime with `/chanakya verify --round N`."
