# Shared: Integration Test Brief Format

```markdown
# Test Brief: <task-id> — Integration Tests: <feature interaction>

**Generated:** <YYYY-MM-DD HH:mm IST>
**Parent task:** <parent-task-id>

---

## Scope

Integration tests verifying <module A> and <module B> work together correctly. These are longer-running tests that exercise real module boundaries without mocking the integration points.

## Module Boundaries Under Test

- <Module A> → <Module B>: <what crosses the boundary — data, events, state>
- <Shared state>: <what both modules read/write>

## Test Scenarios

1. <Scenario: end-to-end data flow>
   - Setup: <preconditions>
   - Action: <what triggers the cross-module interaction>
   - Verify: <expected state in both modules>
2. <Scenario: error propagation across modules>

## What to Mock vs. What's Real

- **Real:** <the module integration itself — don't mock the boundary you're testing>
- **Mock:** <external services, network, disk I/O — anything outside the modules under test>

## Test Organization

- File: `<TestTarget>/Integration/<ModuleA>_<ModuleB>Tests.swift`
- Keep integration tests separate from unit tests (different file/group)
- These tests may take longer — mark them appropriately if the framework supports test categories
```
