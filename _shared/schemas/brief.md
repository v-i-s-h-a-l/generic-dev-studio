---
name: Brief Schema
description: YAML shape for Chanakya-authored Achilles briefs under plans/briefs/<brief-id>.yaml. Contract instance — Chanakya → Achilles. Replaces the markdown brief files in chanakya-tasks/.
type: reference
---

# Brief Schema (`brief@3.8.0`)

Per-brief artifact written to `~/.dev-studio/<project>/plans/briefs/<brief-id>.yaml`. Replaces the markdown briefs that previously lived at `plans/chanakya-tasks/<task-id>-<type>.md`. One file per brief; a task may have many briefs across rework cycles (each with a distinct `id`, same `task_id`).

Version 3.8.0 makes the executable brief quality contract lintable. New direct-to-Achilles implementation briefs must be XS/S/M by default, carry explicit objective / non-goals / measurable acceptance / verification evidence, and include structured model recommendations. L-sized Achilles implementation briefs require an explicit waiver or split rationale. Legacy briefs below 3.8.0 are not retroactively blocked. `write_brief_artifact` callers opt into this gate with `schema_version=3.8.0`; legacy migration/backfill paths stay below 3.8.0 unless they can satisfy the full contract.

Version 3.6.0 adds `recommended_models`, a task-level best-result and fast-turnaround recommendation pair resolved from `_shared/rules/model-recommendation.md` and `_shared/schemas/model-catalog.yaml`. Additive over 3.5.0; readers on 3.0.0+ ignore unknown fields.

Version 3.7.0 adds optional `base_branch`, a dispatch-time branch base for briefs that must start from a non-current branch. Omit it for normal tasks; `task-worktree-setup.sh` falls back to the operator checkout only when this field is absent.

Version 3.5.0 promotes `legacy_task_id` to a documented field (#296). Previously undocumented and caller-dependent — older `task-load-spec.sh` relied on it for brief resolution but hand-authored briefs silently omitted it, breaking Achilles dispatch. The canonical loader now follows `task.links.brief`; `legacy_task_id` remains useful for migration/backfill parity and the optional diagnostic legacy path. `write_brief_artifact` auto-resolves it from the parent task YAML when not passed explicitly, and `validate-brief.sh` enforces presence when the parent task carries one.

Version 3.3.0 adds explicit dispatch routing: `dispatch_agent` (optional enum, default `achilles`) and `evidence` (required when `dispatch_agent: apollo`). Apollo Stage 5 (#235) wiring — perf briefs declare their target agent at brief-write time so dispatch is deterministic and Apollo's strict-9 evidence gate can pre-flight at brief creation rather than at refusal time. Additive over 3.2.0; readers on 3.0.0+ ignore unknown fields and continue dispatching to Achilles.

Version 3.2.0 adds the `summary` field — a ≤500-token compact brief slice for cheap reads (status renders, dispatch tables, agent-boot under tight context budgets). Authoring discipline below. Additive over 3.1.0; readers on 3.0.0+ ignore unknown fields.

Version 3.1.0 bumped from the 3.x object-envelope form introduced in Phase 2.5 — schema carrier is YAML object rather than markdown with YAML preamble, and `reads` / `writes` / `acceptance` / `testability` are structured arrays rather than free-form markdown lists.

## Shape

```yaml
schema_version:
  # brief@3.8.0
  name: brief
  version: 3.8.0
  min_reader: 3.0.0
  deprecated_at: null
id: 0190f52a-6e11-7c01-8a77-11a05a9e2b4c        # UUIDv7
task_id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11   # UUIDv7 of the parent task
legacy_task_id: "T042"                           # human-readable task ID from parent task
type: impl                                       # impl | unit-test | ui-test | integration-test | tdd
size: m                                          # xs | s | m | l
state: ready                                     # draft | ready | dispatched | debriefed | superseded | archived
created_at: 2026-04-22T10:18:02Z
updated_at: 2026-04-22T10:18:02Z
figma:
  file_key: "DMRP0bv9T9oUbGCC5esB01"
  node_ids: ["1:42171"]
reads:
  - "Project/FilterPreset/FilterPresetRow.swift"
  - "Project/FilterPreset/FilterPresetViewModel.swift"
writes:
  - "Project/FilterPreset/FilterPresetRow.swift"
  - "ProjectTests/FilterPreset/FilterPresetRowTests.swift"
acceptance:
  - "Row renders three presets in horizontal scroll view."
  - "Tapping a preset applies it and emits analytics event."
  - "Disabled preset cell shows dimmed state."
testability:
  - "Inject FilterPresetStore via protocol for unit-test seam."
  - "Expose accessibility identifiers on each preset cell."
  - "ViewModel stays struct, no shared state."
rework_of: null                                  # task-id if this brief is a rework
reproducer: null                                 # machine-readable reproducer for bug tasks. Required when parent task type=bug; null otherwise. validate-brief.sh blocks ready-flip when a bug brief has no reproducer.
dispatch_agent: achilles                         # achilles | apollo. Default achilles. Drives Chanakya dispatch + Argus skip.
recommended_models:
  best_result:
    tier: sonnet
    model_id: claude-sonnet-default
    reasoning_effort: medium
  fast_turnaround:
    tier: haiku
    model_id: claude-haiku-default
    reasoning_effort: low
  rationale: "Small low-novelty implementation against established patterns."
base_branch: main                                  # optional; explicit dispatch base when not current checkout
perf_mode: null                                  # null | memory | thermal | battery | cpu. Required when dispatch_agent: apollo.
evidence:                                        # Required when dispatch_agent: apollo. Null otherwise.
  artifacts:                                     # Pre-captured evidence paths (relative to project root or absolute).
    - "~/.dev-studio/<project>/perf/baseline-2026-04-27.trace"
  capture_plan: null                             # If artifacts empty, declare auto-capture path Apollo will run.
  baseline_ref: "main@a1b2c3d"                   # Git ref the baseline was captured against.
summary: |                                       # ≤500 tokens; compact brief slice. Null allowed pre-backfill.
  Adopt OS_LOG categories for the photo-editor pipeline.
  Replaces ad-hoc print() at ~30 call sites; analytics route unchanged.
  Don't change log formatting at call sites — only routing.
body: |
  # Full markdown brief body.
  #
  # The body preserves the original brief template prose — context, steps,
  # figma cross-refs, risk notes. Fields above are the machine-readable
  # contract; `body` is the writer's narrative for Achilles.
```

## Executable Brief Quality Contract (3.8.0)

New executable briefs are worker instructions, not planning epics. They should be compact enough for worker context and concrete enough for Argus to review without reconstructing intent.

Required for `brief@3.8.0+` before a brief transitions to `ready`:

1. `size` defaults to `xs`, `s`, or `m` for direct Achilles implementation work.
2. `size: l` is allowed for parent epics, design/planning containers, or an explicitly waived Achilles implementation brief. A waived L implementation brief must include a non-empty `## L-size reason`, `## Size waiver`, `## Split rationale`, or `## Why not split` section in `body`.
3. `body` includes a non-empty `## Objective` section: one concise changed behavior/output statement.
4. `body` includes explicit `## Out of Scope`, `## Non-goals`, or `## Non-goals / Out of Scope`.
5. `acceptance` is non-empty and written as binary, measurable, UI-testable, unit-testable, or manually verifiable criteria.
6. `body` includes `## Verification`, `## Evidence`, `## Verification / Evidence`, or `## Expected Evidence` with the expected proof Achilles should produce.
7. `recommended_models` is populated with `best_result`, `fast_turnaround`, and a task-specific rationale.

Long background, raw research, and design discussion belong in linked context docs or the compact `summary`, not in the executable worker brief. The brief can reference files and patterns, but it does not need to prescribe exact coordinates unless they affect the expected behavior.

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | object | yes | Per `contracts/schema-version.md`. `min_reader: 3.0.0` — readers on brief@2.x or older reject. |
| `id` | string (UUIDv7) | yes | Stable for the life of this brief. |
| `task_id` | string (UUIDv7) | yes | Parent task. Must resolve to an existing `task.yaml`. |
| `legacy_task_id` | string \| null | no | Human-readable task ID (e.g. `T042`) from the parent task. Auto-resolved by `write_brief_artifact` from `tasks/<task_id>.yaml` when not passed explicitly. Required when the parent task carries one; null for UUID-only tasks. Used by `backfill-legacy-yaml.sh` dedup and the optional `TASK_LOAD_SPEC_DIAGNOSTIC=1` legacy path. |
| `type` | enum | yes | One of `impl`, `unit-test`, `ui-test`, `integration-test`, `tdd`. Drives brief-template expansion in Chanakya's brief mode. |
| `size` | enum | yes | `xs` \| `s` \| `m` \| `l`. Must match the parent task's `size`. |
| `state` | enum | yes | Per `state-machines/brief-lifecycle.md`. |
| `created_at` | RFC3339 UTC | yes | Set once on file creation. |
| `updated_at` | RFC3339 UTC | yes | Bumped on every state transition / edit. |
| `figma` | object \| null | yes | `{file_key, node_ids: []}`. Null for tasks with no Figma reference. |
| `reads` | array of strings | yes | Relative paths from repo root. Declares surface Achilles should read. Empty array allowed. |
| `writes` | array of strings | yes | Relative paths from repo root. Declared write surface. Empty array allowed. |
| `acceptance` | array of strings | yes | Criteria Achilles must satisfy before debriefing. Empty array = no explicit criteria (rare; brief should enumerate). |
| `testability` | array of strings | yes | Testability mandates — DI seams, accessibility IDs, SOLID checklists relevant to this brief. Empty array for test-type briefs where the brief *is* the test plan. |
| `rework_of` | UUIDv7 \| null | yes | Task-id being reworked. Null for first-time briefs. |
| `reproducer` | string \| null | no | Required when parent task `type == bug`; null otherwise. Plain text or numbered steps. Mirrors `## Steps to Reproduce` in `body`. `scripts/validate-brief.sh` blocks `draft → ready` when both this field is null and the body section is absent (#220 A2-1). |
| `dispatch_agent` | enum | no | `achilles` \| `apollo`. Default `achilles`. Determines which worker Chanakya dispatches to and whether Argus runs. Set to `apollo` for perf-mode briefs (memory / thermal / battery). |
| `recommended_models` | object \| null | no | Output of `_shared/rules/model-recommendation.md`: `{best_result, fast_turnaround, rationale}`. Each recommendation carries `tier`, `model_id`, and `reasoning_effort`. Null allowed for pre-3.6.0 briefs; new briefs SHOULD populate it. |
| `base_branch` | string \| null | no | Explicit branch/ref base for dispatch when the task must start somewhere other than the operator's current checkout. Readers try the local ref, then `origin/<base_branch>`. Null/absent preserves existing checkout-derived behavior. |
| `perf_mode` | enum \| null | no | `memory` \| `thermal` \| `battery` \| null. MUST be non-null when `dispatch_agent: apollo`; MUST be null otherwise. Selects the Apollo mode pack. |
| `evidence` | object \| null | no | Required when `dispatch_agent: apollo`; null otherwise. Object: `{artifacts: [paths], capture_plan: string \| null, baseline_ref: string}`. Either `artifacts` is non-empty (pre-captured) OR `capture_plan` describes the auto-capture Apollo will run before recommending a fix. Pre-flights Apollo's strict-9 evidence gate at brief-creation time. |
| `summary` | string \| null | yes | ≤500 tokens (~385 words; lint via `scripts/lint-brief.sh`). Compact brief slice for cheap reads. Null permitted only for briefs authored before 3.2.0; new briefs MUST populate. |
| `body` | string (multiline markdown) | yes | Free-form narrative. Preserves the brief template prose. |

### `summary` authoring discipline

The summary is the **shortest fact-dense description that lets a reader decide whether to load the full brief**. Not a TLDR of acceptance criteria — those live in `acceptance`. Three lines max:

1. What this task changes (one sentence).
2. Why it matters / what triggers it (one sentence).
3. Key constraint or non-obvious assumption (one sentence).

Consumers (`/chanakya status`, `/chanakya dispatch-ready`, `/chanakya digest`, Achilles agent-boot under `BRIEF_SLICE=summary`) render the field directly — no further trimming. Lint refuses summaries longer than 500 tokens (estimated as `word_count × 1.3`).

## Lifecycle

See `state-machines/brief-lifecycle.md`. Summary:

```
draft → ready → dispatched → debriefed → archived
ready → superseded (rework replaces this brief)
dispatched → superseded (mid-flight replacement; rare)
```

Transitions emit `brief_state_changed` per `contracts/events.md`.

## Out of scope

The schema deliberately omits a base-branch tip SHA field (#264). Brief-write time and dispatch time are minutes-to-hours apart; a SHA captured at write time goes stale before the worktree is set up. `base_branch` may name a branch/ref, but base-stale detection is dispatch-time only — `task_started.base_sha` records the live SHA at Step 2 and `base_refreshed` / `base_refresh_conflict` (Step 8.4) handle drift. Brief writers MUST NOT add a tip SHA to `body` prose either; the brief is the spec, the live tree is the SHA.

## Links

- `task_id` back-references the parent task. Bidirectional consistency checked by the plans-index validator.
- `rework_of` names the task the current brief is a rework of (not the prior brief-id — a task can be re-briefed multiple times and each points back to the task, not to the chain of prior briefs).

## Migration note (2.6)

Legacy markdown briefs at `plans/chanakya-tasks/<task-id>-<type>.md` migrate to `plans/briefs/<brief-id>.yaml` via `scripts/migrate-ledger.sh`. The transform:

1. Parses the legacy YAML-preamble + markdown body.
2. Mints a UUIDv7 for `id` (derived deterministically from source file mtime + path so reruns are stable).
3. Rewrites the markdown as `body:` multi-line string.
4. Resolves `task_id` from the task-id slug in the legacy filename.
5. Promotes `reads` / `writes` / `acceptance` / `testability` from the preamble.

Unparseable briefs (malformed YAML preamble, missing task-id) land in `archive/2026-pre-2.6/unparseable/` with a line-numbered report.

## History table

| Version | Landed | Changes |
|---|---|---|
| 3.8.0 | 2026-05-01 | Added lintable executable brief quality contract (#323): XS/S/M default for Achilles implementation briefs, explicit L-size waiver, objective, non-goals, measurable acceptance, verification evidence, and structured model recommendations. |
| 3.7.0 | 2026-04-30 | Added optional `base_branch` for explicit dispatch bases (#374). Additive; `min_reader: 3.0.0`. |
| 3.6.0 | 2026-04-30 | Added optional `recommended_models` pair for task-level model selection (#65). Additive; `min_reader: 3.0.0`. |
| 3.5.0 | 2026-04-28 | Promoted `legacy_task_id` to documented field (#296). Auto-resolved by `write_brief_artifact`; `validate-brief.sh` enforces presence. Fixes Achilles dispatch failure on hand-authored briefs. Additive; `min_reader: 3.0.0`. |
| 3.4.0 | 2026-04-27 | Added `reproducer` field — machine-readable bug reproducer, required when parent task `type: bug` (#220 A2-1). Additive; `min_reader: 3.0.0`. |
| 3.3.0 | 2026-04-27 | Added `dispatch_agent` / `perf_mode` / `evidence` fields — explicit dispatch routing + Apollo evidence pre-flight (#235). Additive; `min_reader: 3.0.0`. |
| 3.2.0 | 2026-04-27 | Added `summary` field — ≤500-token compact brief slice (#256). Additive; `min_reader: 3.0.0`. |
| 3.1.0 | 2026-04-22 | Full YAML shape — `reads` / `writes` / `acceptance` / `testability` promoted to structured arrays; markdown body kept as multi-line string. `min_reader: 3.0.0`. |
| 3.0.0 | 2026-04-15 (pre-2.6 envelope form) | Added `schema_version` object, `correlation_id`. |
| 2.x | pre-2026-04-15 | Markdown with YAML preamble; legacy. |

## Related

- `contracts/brief-formats/` — per-type template prose rendered into `body`.
- `state-machines/brief-lifecycle.md` — transitions.
- `schemas/task.md` — parent artifact.
- `schemas/debrief.md` — output produced when `state: debriefed`.
- `rules/model-recommendation.md` — deterministic model recommendation rule.
