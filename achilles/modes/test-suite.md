---
name: Achilles Test-Suite
description: Composite test-suite mode (`/achilles test-suite <unit|ui|all>`). Runs the full test suite (not individual task tests) against committed HEAD and produces a debrief that resets the corresponding debt counter on Chanakya's next sweep.
type: mode-pack
snapshots: []
budget_tokens: 1500
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
   Write a debrief to `chanakya-inbox/`:
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
   Chanakya processes this and resets the corresponding debt counter.

5. **Red result (any test fails):**
   Write a debrief with `test_result: fail` and list failing tests:
   ```markdown
   ## Failing Tests
   - FilterPresetManagerTests.testSavePreset_withEmptyName: expected error, got success
   - CropViewUITests.testRotation360: element not found
   
   ## Follow-up Tasks
   - P0 fix: N failing tests. See failing test list above.
   ```
   Debt counter is NOT reset on red. Chanakya files a follow-up fix task.

6. **Cleanup.** Remove worktree and DerivedData (same as Build Mode green path). On red, retain for inspection.

7. **Report:**
   > "Test suite (unit): 142 tests, all green. Debrief dropped — unit test debt will reset on next Chanakya sweep."
   Or:
   > "Test suite (ui): 38 tests, 2 failing. Debrief dropped with failures. Debt counter unchanged."
