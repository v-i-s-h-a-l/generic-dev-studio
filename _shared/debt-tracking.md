---
name: Debt Tracking
description: Build debt + unit/UI test debt counters, thresholds, banner rules, and brief-mode refusal behavior. Consumed by Chanakya's inbox-sweep and brief modes.
type: reference
---

# Debt Tracking (Build + Unit Test + UI Test)

Chanakya maintains three independent debt counters. All three are evaluated on every inbox sweep (Step 0A) and on every mode entry (banner rules).

## Build Debt Tracking

Schema, counter update rules, and state transitions: see `~/.claude/skills/_shared/build-debt-schema.md`.

### Banner rules

Before executing any mode (including intake, status, brief, review, update, test-manifest, test-flow, review-feedback), inspect `State:` for all three debt trackers (build, unit test, UI test):

- `silent` → no banner.
- `warn` → print once at the top:
  > "⚠️ Build debt: `<n>` tasks merged without a full build (`<id-list>`). Open check: `TBUILD-<n>`. Block at 12 — `<12-n>` more until new work is refused."
- `block` → print once at the top:
  > "⛔ Build debt BLOCKED (counter=`<n>`, or red-build outstanding via `<T-fix-id>`). Run `/achilles build` (or complete `<T-fix-id>`) to unblock. New briefs refused; overrides are via `/achilles <id> --ignore-build-debt`."

### Brief-mode refusal under `block`

In Brief Generation mode (`/chanakya brief <task-id>`), if `State: block`:

- If the task-id is a `TBUILD-*` or the P0 fix referenced by `Blocked by:`, proceed — these are the unblocking tasks.
- Otherwise refuse, print the block banner, and exit without writing.

## Test Debt Tracking

Two independent debt counters track implementation tasks that merge without their test sub-tasks being completed. These work alongside build debt — all three are evaluated on every inbox sweep.

### Master plan header

```markdown
## Test Debt

### Unit Test Debt
- Counter: 3 / warn@4 / block@8
- State: silent            <!-- silent | warn | block -->
- Last green run: —        <!-- timestamp of last full unit-test suite pass -->
- Untested since: [T015, T018, T022]
- Open check task: —       <!-- TUNIT-<n> when auto-filed -->
- Next TUNIT n: 1

### UI Test Debt
- Counter: 2 / warn@3 / block@6
- State: silent            <!-- silent | warn | block -->
- Last green run: —        <!-- timestamp of last full UI-test suite pass -->
- Untested since: [T015, T022]
- Open check task: —       <!-- TUI-<n> when auto-filed -->
- Next TUI n: 1
```

### Counter update rules (applied during Step 0A per debrief)

**Unit test debt** increments when an implementation task (`Type: feature | bugfix | refactor`) merges but its unit test sub-task (same Group, `Type: test-unit`) is still `pending` or `briefed`:

| Implementation debrief processed | Unit test sub-task status | Action |
|---|---|---|
| Implementation task done | test-unit sub-task `done` or `verified` | No change (tests shipped with implementation) |
| Implementation task done | test-unit sub-task `pending` or `briefed` | Counter += 1; append task-id to `Untested since` |
| Implementation task done | No test-unit sub-task exists | Counter += 1; append `<task-id>[no-test-task]` to `Untested since` |
| test-unit sub-task done | (processed independently) | Counter -= 1; remove parent from `Untested since` |

**UI test debt** follows the same logic for `Type: test-ui` sub-tasks. Only applies to tasks that have a UI test sub-task in their group.

**Resetting the counter:** When a full test suite run passes (tracked via a `TUNIT-<n>` or `TUI-<n>` task), reset the respective counter to 0 and clear `Untested since`.

### Threshold actions

**Unit test debt:**

| Counter | State | Action |
|---|---|---|
| 0 – 3 | silent | Normal operation |
| 4 – 7 | warn | Banner on every Chanakya invocation. Auto-file `TUNIT-<n>` (P1, `Type: test-suite-run`) at 3→4 transition |
| ≥ 8 | block | Banner + refuse new implementation briefs until unit test debt is reduced. Test sub-task briefs are always allowed. |

**UI test debt** (tighter thresholds — UI tests are slower to accumulate and more expensive to catch up on):

| Counter | State | Action |
|---|---|---|
| 0 – 2 | silent | Normal operation |
| 3 – 5 | warn | Banner on every Chanakya invocation. Auto-file `TUI-<n>` (P1, `Type: test-suite-run`) at 2→3 transition |
| ≥ 6 | block | Banner + refuse new implementation briefs until UI test debt is reduced |

### Banner rules

Evaluate after build debt banners. Show the most severe state first:

- `silent` → no banner.
- `warn` (unit tests) → print once:
  > "⚠️ Unit test debt: `<n>` implementation tasks merged without unit tests (`<id-list>`). Open check: `TUNIT-<n>`. Block at 8."
- `warn` (UI tests) → print once:
  > "⚠️ UI test debt: `<n>` implementation tasks merged without UI tests (`<id-list>`). Open check: `TUI-<n>`. Block at 6."
- `block` → print once:
  > "⛔ Test debt BLOCKED (unit: `<n>`, UI: `<n>`). Complete pending test sub-tasks or run the test suite to unblock. New implementation briefs refused."

### Brief-mode interaction with test debt block

When unit or UI test debt is in `block` state:

- **Implementation briefs** (feature/bugfix/refactor) are refused, same as build debt block.
- **Test briefs** (test-unit, test-integration, test-ui) are always allowed — they're the solution.
- **TUNIT / TUI tasks** are always allowed.
- If BOTH build debt and test debt are blocked, show both banners. Resolving one doesn't unblock the other.

### Auto-filed check tasks

**`TUNIT-<n>`** (auto-filed at warn threshold):
- Type: `test-suite-run`
- Priority: P1
- Description: "Run the full unit test suite. Covers: [T015, T018, T022]. All tests must pass."
- Achilles runs `xcodebuild test` for the unit test target, reports results in debrief.

**`TUI-<n>`** (auto-filed at warn threshold):
- Type: `test-suite-run`
- Priority: P1
- Description: "Run the full UI test suite. Covers: [T015, T022]. All tests must pass."
- Achilles runs `xcodebuild test` for the UI test target, reports results in debrief.
