---
name: Achilles Test-Suite
description: Composite test-suite mode (`/achilles test-suite <unit|ui|all>`). Runs the full test suite (not individual task tests) against committed HEAD and produces a debrief that resets the corresponding debt counter on Chanakya's next sweep.
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: []
budget_tokens: 1500
reads:
  - plans/index.yaml                               # post-migration relational index
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/chanakya-master.md                       # legacy fallback until Commit H
writes:
  - plans/debriefs/<debrief-id>.yaml               # post-migration canonical (schema: _shared/schemas/debrief.md, debrief@2.0.0, test-suite-run kind)
  - plans/chanakya-inbox/test-suite-<stamp>-debrief.md  # legacy markdown debrief during Phase 2.6 transition
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Composite: Test-Suite Mode (`/achilles test-suite <unit | ui | all>`)

Run the full test suite (not individual task tests) and produce a debrief that resets the corresponding debt counter.

This mode short-circuits the normal task pipeline — no branch, no merge, no Argus gate (same exception as build mode). Detached-HEAD worktree against committed HEAD.

## Steps

1. **Select the test target:**
   - `unit` → run the unit test target(s)
   - `ui` → run the UI test target(s)
   - `all` → run both sequentially (unit first, then UI)

2. **Isolate.** Create a detached-HEAD worktree (same as Build Mode — no branch, no merge). This ensures the test run is against committed HEAD.

3. **Execute tests.** Run the appropriate `xcodebuild test` command(s) through the serialized build lock:
   ```bash
   xcodebuild test -scheme <scheme> -destination <dest> \
     -derivedDataPath "$DERIVED" \
     -only-testing:<TestTarget>
   ```
   Capture: pass count, fail count, individual test names and results, duration.

4. **Green result (all tests pass):**
   Write the debrief as YAML to `~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml` per schema `_shared/schemas/debrief.md` (`debrief@2.0.0`). Mint `id` as a UUIDv7. Populate `schema_version`, `task_id: null` (test-suite runs are not task-scoped), `brief_id: null`, `mode: task` (test-suite-run is treated as a task-mode variant — the structured `tests` object + `key_learnings` carry the suite context), `completed_at`, `branch: {worked_on: null, merged_into: null, merge_sha: <HEAD_SHA>}` (detached-HEAD worktree; no branch), `commits: []`, `diff_summary: {files: 0, added_lines: 0, removed_lines: 0}`, `decisions: []`, `tests: {added: [], modified: [], skipped_because: null}` (the suite exercises existing tests — `added` stays empty), `testability: null`, `build_gate: full-green`, `build_debt_override: false`, `debt: {build: false, test_unit: false, test_ui: false, notes: null}` (green result — debt counter reset is Chanakya's derived action, not a field), `performance: []`, `key_learnings: ["test-suite-run kind: <unit|ui|all>", "tests_run: <N>", "tests_passed: <N>", "tests_failed: 0", "duration_s: <secs>"]`, `known_issues: []`, `follow_ups: []`, `open_questions: []`, `argus_review: {status: not-invoked, review_id: null, notes: "test-suite-run; no merge, no argus gate"}`.

   Chanakya's inbox sweep reads the `key_learnings` + green/red signal and resets the corresponding debt counter.

   **Phase 2.6 transition note:** also write the legacy markdown debrief at `plans/chanakya-inbox/test-suite-<stamp>-debrief.md` until Commit H cutover:
   ```markdown
   # Debrief: test-suite-<stamp> — Test suite run
   Type: test-suite-run
   Completed: <timestamp>
   HEAD: <sha>
   Suite: unit | ui | all

   ## Test Results
   test_result: pass
   Tests run: 142
   Tests passed: 142
   Tests failed: 0
   Duration: 45s

   ## Coverage
   - <module>: <pass>/<total>
   ```

5. **Red result (any test fails):**
   Write the debrief YAML with the same shape as green, but populate `known_issues` and `follow_ups` with the failures:
   - `key_learnings` includes `tests_failed: <N>` and a truncated list.
   - `known_issues` lists each failing test name (e.g., `"FilterPresetManagerTests.testSavePreset_withEmptyName: expected error, got success"`).
   - `follow_ups` lists: `"P0 fix: N failing tests. See known_issues."`.

   Debt counter is NOT reset on red — Chanakya files a follow-up fix task from `follow_ups[]`.

   **Phase 2.6 transition note:** also write the legacy markdown form with `test_result: fail`, the `## Failing Tests` section, and the `## Follow-up Tasks` section until Commit H cutover.

6. **Cleanup.** Remove worktree and DerivedData (same as Build Mode green path). On red, retain for inspection.

7. **Report:**
   > "Test suite (unit): 142 tests, all green. Debrief dropped — unit test debt will reset on next Chanakya sweep."
   Or:
   > "Test suite (ui): 38 tests, 2 failing. Debrief dropped with failures. Debt counter unchanged."
