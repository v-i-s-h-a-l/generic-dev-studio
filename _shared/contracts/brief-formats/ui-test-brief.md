# Shared: UI Test Brief Format

```markdown
# Test Brief: <task-id> — UI Tests: <user flow>

**Generated:** <YYYY-MM-DD HH:mm IST>
**Parent task:** <parent-task-id>

---

## Scope

UI tests for <user flow>. Test the end-to-end user journey through the UI.

## Accessibility Identifier Contract

The implementation task (<parent-task-id>) defines identifiers in:
- **Identifier file:** `<path to AccessibilityID enum file>`
- **Key identifiers for this flow:**
  - `AccessibilityID.<Screen>.<element>` — <what it identifies>

If the implementation hasn't landed yet (TDD mode), define the expected identifiers here — the implementation must satisfy them.

## User Flows to Test

### Flow 1 — <Flow name> (happy path)
1. Launch → <initial screen>
2. Tap <element> (`AccessibilityID.<Screen>.<element>`)
3. Verify <expected state>
Expected end state: <what the user sees>

### Flow 2 — <Edge case flow>

### Flow 3 — <Error/recovery flow>

## Test Organization

- File: `<UITestTarget>/<Module>/<FlowName>UITests.swift`
- Group test suites per module/feature
- For bug fixes: add a regression test reproducing the original bug
- Reuse page objects if the project has them; create one if 3+ tests interact with the same screen
- Remove redundant tests that duplicate coverage from new tests

## Performance Considerations

- Minimize app re-launches between tests (use `setUpWithError` for state reset where possible)
- Tests should be independent — no test ordering assumptions
- Target: full UI test suite for this module runs in <N minutes>
```
