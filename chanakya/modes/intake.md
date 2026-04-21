---
name: Chanakya Intake
description: Initial task capture + planning — take a PRD or bullet points, tier into plan-worthy vs direct, expand into task groups with sub-task decisions (unit/integration/UI tests, TDD vs test-after), assign skills, write the master plan.
type: mode-pack
snapshots: [briefs.json]
budget_tokens: 4000
reads: []
writes: []
---

# Mode: Intake (`/chanakya intake` or `/chanakya` with no args)

Entry point when there's no existing master plan (or the user has fresh work to add). Produces `chanakya-master.md`.

Snapshots: `snapshots/briefs.json` for existing-task lookup when merging (5-min freshness; fallback: read `chanakya-master.md` directly — this is the authoritative source at intake time).

## Step 1 — Gather tasks

Ask the user: "What are you working on? Paste bullet points, Figma URLs, PRD references, crash logs, or just describe the features."

Accept any format. For each task, extract:
- **Title** (short imperative phrase)
- **Description** (what needs to happen)
- **Priority** (P0 = blocking/urgent, P1 = important, P2 = nice-to-have)
- **Figma references** (URLs or node IDs, if mentioned)
- **Dependencies** (does this block or depend on another task?)
- **Estimated complexity** (S/M/L/XL)

## Step 2 — Read existing master plan

If `~/.dev-studio/<project>/plans/chanakya-master.md` exists, read it. Merge new tasks with existing ones. Assign task IDs continuing from the highest existing ID (format: `T001`, `T002`, ...).

If no master plan exists, create the initial version.

## Step 3 — Tier tasks

Classify each task:
- **Plan-worthy** (features, refactors, multi-module work) → gets a brief
- **Direct** (bug fixes, small tweaks, single-file changes) → logged as `direct` type, no brief needed

Tell the user: "T001 and T002 need briefs (multi-file features). T003 is a simple bug fix — send it directly to Achilles when ready."

## Step 4 — Expand into task groups

Every plan-worthy task (and most non-trivial direct tasks) becomes a **task group** — a set of linked tasks covering implementation through testing. For each task, determine which sub-tasks are warranted:

| Sub-task | When to create | Blocked by |
|----------|---------------|------------|
| **Implementation** (always) | Always | Dependencies from Step 1 |
| **Unit tests** | Always for plan-worthy tasks. For direct tasks: create if the change touches business logic, models, or view models. Skip for pure UI-only or config-only changes. | Implementation task |
| **Integration tests** | When the feature spans 2+ modules, touches shared state, or modifies APIs consumed by other modules. | Implementation task |
| **UI tests** | When the feature has a user-visible flow with ≥2 interaction steps. Skip for backend-only, model-only, or infrastructure changes. | Implementation task |

**TDD vs. test-after decision:**

- **New features** (greenfield, no existing code): Prefer TDD — create the unit test task *before* implementation, with `blockedBy` reversed. The test task defines expected interfaces; the implementation satisfies them. Mark the test task as `Type: test-tdd`.
- **Bug fixes / changes to existing code**: Test-after — implementation first, then test tasks. Mark test tasks as `Type: test-after`.
- **Refactors**: If tests already exist and will break, update tests as part of the implementation task (no separate test task). If no tests exist, create a test-after task.

**Naming convention:**

```
T015   — Add filter presets                    (Type: feature)
T015a  — Unit tests: filter presets            (Type: test-unit, Group: T015)
T015b  — Integration tests: filter + texture   (Type: test-integration, Group: T015)
T015c  — UI tests: filter selection flow       (Type: test-ui, Group: T015)
```

Sub-task IDs use the parent ID + suffix (`a`, `b`, `c`). This keeps the group visually clustered in the master plan and parallelization map.

**What goes into each sub-task at intake (briefs are generated later in Brief mode):**

- **Implementation task:** Standard fields + `## Testability Requirements` placeholder (filled at brief time).
- **Unit test task:** Reference to parent implementation task. Key areas to test (derived from acceptance criteria). Note: "Use the project's testing framework. Follow existing test organization patterns."
- **Integration test task:** Which module boundaries to exercise. Expected interaction patterns.
- **UI test task:** User flow steps (from Figma or PRD). Note: "Use accessibility identifiers defined by the implementation task."

## Step 5 — Assign skills

For each task in the group, determine relevant skills:

| Skill | Use when |
|-------|----------|
| `figma-to-swiftui` | New SwiftUI views from Figma |
| `swiftui-liquid-glass` | iOS 26+ glass effects |
| `swiftui-pro` | Any SwiftUI view work |
| `swiftui-view-refactor` | Splitting/restructuring views |
| `swiftui-performance-audit` | Performance-sensitive views (lists, scrolling, animations) |
| `swift-concurrency-pro` | Async/await, actors, Sendable |
| `swift-testing-expert` | Writing or updating tests (assign to ALL test sub-tasks) |
| `imgly-engine-expert` | IMGLY engine, blocks, effects |
| `swift-architecture-skill` | Architecture decisions, MVVM patterns |

**Always assign `swift-testing-expert`** to unit test, integration test, and UI test sub-tasks. For implementation tasks, assign it when the brief will include testability requirements.

Apply the skill assignments and record them in the write summary.

## Step 6 — Write master plan

Write/update `~/.dev-studio/<project>/plans/chanakya-master.md` using the format below. Task groups are written with the parent task first, followed by its sub-tasks indented under it.

## Step 7 — Propose parallelization

Suggest which tasks can run in parallel (independent) and which must be sequential (dependencies). Render an ASCII dependency graph. Task groups show internal dependencies:

```
T015 (implementation)
  ├── T015a (unit tests)      ← blocked by T015
  ├── T015b (integration)     ← blocked by T015
  └── T015c (UI tests)        ← blocked by T015
T016 (implementation)         ← independent of T015 group
  └── T016a (unit tests)      ← blocked by T016
```

Note: Test sub-tasks within different groups CAN run in parallel (T015a and T016a are independent).

## Step 8 — Suggest next action

"Master plan created with N task groups (X implementation tasks, Y unit test tasks, Z UI test tasks). Starting T001 briefing (highest priority)..."

Auto-start briefing T001 immediately after printing this message.

## Master Plan Format

Full schema: `~/.claude/skills/_shared/schemas/master-plan.md`.
