---
name: Chanakya Intake
description: Initial task capture + planning — PRD/bullets in, similarity-probe for duplicate-fold, tier plan-worthy vs direct, expand into task groups (unit/integration/UI tests), write master plan.
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: [briefs.json]
budget_tokens: 4000
reads:
  - plans/index.yaml                               # post-migration task index for existing-task lookup
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
writes:
  - plans/tasks/<task-id>.yaml                     # post-migration canonical (schema: _shared/schemas/task.md, task@1.0.0)
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh after artifact writes
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Intake (`/chanakya intake` or `/chanakya` with no args)

Entry point for fresh work. Mints task artifacts under `plans/tasks/<uuid>.yaml` via `lib-ledger.write_task_artifact`.

Snapshots: `snapshots/briefs.json` for existing-task lookup when merging (5-min freshness; fallback: `scripts/query-plans.sh --kind=task`).

## Step 1 — Gather tasks

Ask the user: "What are you working on? Paste bullet points, Figma URLs, PRD references, crash logs, or just describe the features."

Accept any format. For each task, extract:
- **Title** (short imperative phrase)
- **Description** (what needs to happen)
- **Priority** (P0 = blocking/urgent, P1 = important, P2 = nice-to-have)
- **Figma references** (URLs or node IDs, if mentioned)
- **Dependencies** (does this block or depend on another task?)
- **Estimated complexity** (S/M/L/XL)

## Step 2 — Read existing tasks

List existing tasks via `scripts/query-plans.sh --kind=task` against `plans/tasks/*.yaml`. Merge new tasks with existing ones; resolve ID collisions by issuing fresh UUIDv7 `id`s. The human-readable `T<nnn>` prefix comes from `scripts/next-task-id.sh` — see Step 6. Do not infer it from context here.


If neither surface has prior state, this is a fresh project — proceed to Step 3 with an empty set.

## Step 2A — Similarity probe (per candidate task)

Before tiering or expanding into groups, run the duplicate-fold probe against every newly-captured candidate. This catches "we already filed this" before a task ID is minted.

For each candidate `{title, touchpoints?}` from Step 1:

```bash
scripts/similarity-probe.sh --title "<candidate title>" \
  --touchpoints "<glob1,glob2>"   # optional; pass when Step 1 inferred them
```

The script returns up to 5 ranked matches, one per line: `<score>\t<legacy>\t<uuid>\t<state>\t<title>`. Score is a Jaccard-weighted blend of title-token overlap (70%) and touchpoint overlap (30%); matches below 0.20 are dropped. Tasks already `archived`, `cancelled`, or `duplicate_of`-marked are skipped.

When at least one match returns, surface to the user:

> "T347 (`Add filter preset row to photo editor`, state: briefed) looks similar to your candidate `Add filter preset row`. Treat as:
> - **(d)uplicate** — fold into T347, no new task created.
> - **(s)imilar** — knowledge-layer hint only; mint the new task with `similar_to: [T347]` and proceed.
> - **(n)ew** — distinct work; mint normally."

Apply the user's choice:
- `(d)uplicate` — skip Steps 3–6 for this candidate. If the user wants the fold *recorded* (rather than discarded silently), mint a stub task with `state: cancelled` and `duplicate_of: <canonical-uuid>` so the audit trail survives. Default behavior is silent skip.
- `(s)imilar` — proceed to Step 3 with `similar_to: [<canonical-uuid>]` recorded for the eventual `write_task_artifact` call.
- `(n)ew` — proceed normally; no edge recorded.

When the probe returns no matches, proceed to Step 3 silently.

The heuristic is deliberately simple (Jaccard over title tokens + touchpoint globs). Phase 2.7's knowledge layer will replace it with embedding-based search; the probe contract (input → ranked matches) is stable across that swap.

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

Sub-task IDs use the parent ID + suffix (`a`, `b`, `c`). This keeps the group visually clustered in the index and parallelization map.

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

## Step 6 — Write task artifacts

For each newly-captured task (implementation + any sub-tasks), call `write_task_artifact` from lib-ledger — it writes the YAML canonical form (schema `_shared/schemas/task.md`, `task@1.0.0`), seeds `history:`, emits `task_state_changed null → proposed`, and regenerates `plans/index.yaml`. Do not hand-write the YAML.

**Concrete invocation** (run in the Bash tool):

```bash
source scripts/lib-paths.sh
source scripts/lib-ledger.sh

# Allocate the human-readable T-number. Scans YAML + event log; the only
# authoritative source — never guess from in-context samples.
LEGACY_ID=$(scripts/next-task-id.sh)   # e.g. "T268"

TASK_UUID=$(mint_uuidv7)
write_task_artifact "$TASK_UUID" proposed "<title>" \
  legacy_task_id="$LEGACY_ID" \
  size=<s|m|l> \
  type=<feature|bugfix|refactor|test-unit|test-integration|test-ui|direct>
```

The helper initializes `links.{brief,debrief,reviews,release,feedback}` to their zero values, seeds the first `history:` entry, and sets `created_at`/`updated_at` to a single RFC3339 UTC timestamp.

For sub-tasks (T268a/b/c under T268), call `write_task_artifact` once per sub-task with `legacy_task_id=T268a` etc. The parent/child relationship lives in the human-readable title prefix and in the `plans/index.yaml` rollup (the index generator clusters on title prefix). `task@1.0.0` does not encode a `group` field — keeping the schema narrow is deliberate.

**XS tasks.** `size=xs` is introduced separately for trivial direct tasks. Emit `type=direct` together with `size=xs` for those.

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

"Filed N task groups (X implementation tasks, Y unit test tasks, Z UI test tasks). Starting T001 briefing (highest priority)..."

Auto-start briefing T001 immediately after printing this message.

## Task schema

Full schema: `_shared/schemas/task.md` (`task@1.0.0`).
