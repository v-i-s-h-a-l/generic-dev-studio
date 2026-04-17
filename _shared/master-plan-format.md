# Shared: Master Plan Format

```markdown
# <Project> — Master Plan

**Updated:** <YYYY-MM-DD HH:mm IST>

---

## Build Debt

- Counter: 0 / warn@6 / block@12
- State: silent
- Last green: —
- Last green SHA: —
- Unverified since: []
- Open check task: —
- Blocked by: —
- Next TBUILD n: 1

<!-- Thresholds are configurable. Do not hand-edit Counter/State — Chanakya's Step 0 owns them. -->

## Test Debt

### Unit Test Debt
- Counter: 0 / warn@4 / block@8
- State: silent
- Last green run: —
- Untested since: []
- Open check task: —
- Next TUNIT n: 1

### UI Test Debt
- Counter: 0 / warn@3 / block@6
- State: silent
- Last green run: —
- Untested since: []
- Open check task: —
- Next TUI n: 1

<!-- Do not hand-edit — Chanakya's Step 0 owns these counters. -->

---

## Tasks

### T001 — <Title>
- **Priority:** P0
- **Status:** pending   <!-- pending | briefed | in-progress | done | verified | needs-review -->
- **Complexity:** L
- **Type:** feature   <!-- feature | bugfix | refactor | direct | build-check | test-unit | test-integration | test-ui | test-tdd -->
- **Group:** —   <!-- parent task ID for test sub-tasks. "—" for standalone/parent tasks -->
- **Branch:** —
- **Skills:** figma-to-swiftui, swiftui-pro
- **Figma nodes:** `DMRP0bv9T9oUbGCC5esB01` node `1:42171`
- **Dependencies:** none
- **Source:** —   <!-- parent task ID if this came from a debrief's Follow-up Tasks -->
- **Brief:** —
- **Commits:** —
- **Merge commit:** —
- **Test coverage:** —   <!-- for implementation tasks: list sub-task IDs, e.g., "T001a (unit), T001c (UI)" -->
- **Released in:** —   <!-- e.g., "TF-3031, AS-3031" — filled by Chanakya on release debrief processing -->
- **Verified at:** —   <!-- timestamp when user signed off via review-feedback -->
- **Slack row:** —   <!-- e.g., "F0ASZ6B22SZ / Rec0AT0SF7HM4" if linked to Slack list -->
- **Slack status (last synced):** —
- **Notes:** <any context>

#### T001a — Unit Tests: <Title>
- **Priority:** P0
- **Status:** pending
- **Complexity:** M
- **Type:** test-unit
- **Group:** T001
- **Branch:** —
- **Skills:** swift-testing-expert
- **Dependencies:** T001
- **Brief:** —
- **Commits:** —
- **Merge commit:** —
- **Notes:** —

#### T001c — UI Tests: <Title>
- **Priority:** P0
- **Status:** pending
- **Complexity:** M
- **Type:** test-ui
- **Group:** T001
- **Branch:** —
- **Skills:** swift-testing-expert
- **Dependencies:** T001
- **Brief:** —
- **Commits:** —
- **Merge commit:** —
- **Notes:** —

---

## Parallelization Map

(render ASCII dependency graph here)

---

## Completed

| ID | Title | Completed | Verified | Commits | Branch |
|----|-------|-----------|----------|---------|--------|

---

## Release Log

| Build | Version | Type | Date | Tag | HEAD | Tasks Included |
|-------|---------|------|------|-----|------|---------------|

<!-- Populated by Chanakya's Step 0B2 when processing release debriefs -->

---

## Changelog

- <YYYY-MM-DD HH:mm>: <what changed>
```
