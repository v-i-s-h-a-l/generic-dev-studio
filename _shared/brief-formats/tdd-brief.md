# Shared: TDD Test Brief Format

Used for `Type: test-tdd` tasks, where tests are written before the implementation exists.

```markdown
# TDD Brief: <task-id> — Tests First: <feature>

**Generated:** <YYYY-MM-DD HH:mm IST>
**Implementation task:** <impl-task-id> (blocked by this task)

---

## Purpose

Define the expected interfaces and behaviors via failing tests. The implementation task (<impl-task-id>) will make these tests pass.

## Expected Interfaces

Define the protocols, method signatures, and behaviors the implementation must satisfy:

```swift
protocol <ProtocolName> {
    func <method>(<params>) -> <return>
}
```

## Test Scenarios (to write as failing tests)

1. <Scenario>
   - Given: <precondition>
   - When: <action>
   - Then: <expected outcome>

2. <Scenario>

## Stub Strategy

Write placeholder protocols/stubs that satisfy compilation but fail assertions. Do NOT implement — the impl task does that.

## Acceptance Criteria

1. Tests compile against placeholder stubs
2. Tests fail on placeholder stubs (assertion failure, not compilation error)
3. Debrief lists exact interfaces the implementation must satisfy
4. Implementation task (<impl-task-id>) is blocked until this task is `done`
```
