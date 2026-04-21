# Shared: Unit Test Brief Format

```markdown
# Test Brief: <task-id> — Unit Tests: <feature>

**Generated:** <YYYY-MM-DD HH:mm IST>
**Parent task:** <parent-task-id>
**Implementation brief:** <path to parent's brief>

---

## Scope

Unit tests for <feature>. Test business logic, view models, and model transformations in isolation.

## Testing Framework

Use the project's testing framework (Swift Testing / XCTest). Follow existing test file organization.

## Reference Implementation

- **Source files to test:** <list from parent brief's Files to Modify>
- **Existing tests to reference:** <similar test files found in codebase>
- **Test helpers available:** <shared mocks, fixtures, utilities>

## Key Areas to Test

1. <Area 1 — derived from acceptance criteria>
   - Happy path: <expected behavior>
   - Edge cases: <boundary conditions, empty states, nil handling>
   - Error cases: <invalid input, failure modes>
2. <Area 2>

## Test Organization

- File: `<TestTarget>/<Module>/<FeatureName>Tests.swift`
- Group tests by the type/method under test
- Use descriptive test names that read as specifications
- Reuse existing test helpers; create new shared helpers if a pattern repeats 3+ times

## Dependencies to Mock

- <Protocol>: <what it does, mock strategy>

## Acceptance Criteria

1. All public methods of <type> have test coverage
2. Edge cases for <specific scenarios> are covered
3. Tests are independent (no shared mutable state, no test ordering dependency)
4. Tests run in <target time — e.g., under 5s for the suite>
```
