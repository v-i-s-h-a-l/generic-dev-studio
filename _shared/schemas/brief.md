---
name: Brief Schema
description: YAML shape for Chanakya-authored Achilles briefs under plans/briefs/<brief-id>.yaml. Contract instance — Chanakya → Achilles. Replaces the markdown brief files in chanakya-tasks/.
type: reference
---

# Brief Schema (`brief@3.1.0`)

Per-brief artifact written to `~/.dev-studio/<project>/plans/briefs/<brief-id>.yaml`. Replaces the markdown briefs that previously lived at `plans/chanakya-tasks/<task-id>-<type>.md`. One file per brief; a task may have many briefs across rework cycles (each with a distinct `id`, same `task_id`).

Version 3.1.0 bumps from the 3.x object-envelope form introduced in Phase 2.5 — schema carrier is now YAML object rather than markdown with YAML preamble, and `reads` / `writes` / `acceptance` / `testability` are structured arrays rather than free-form markdown lists.

## Shape

```yaml
schema_version:
  name: brief
  version: 3.1.0
  min_reader: 3.0.0
  deprecated_at: null
id: 0190f52a-6e11-7c01-8a77-11a05a9e2b4c        # UUIDv7
task_id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11   # UUIDv7 of the parent task
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
body: |
  # Full markdown brief body.
  #
  # The body preserves the original brief template prose — context, steps,
  # figma cross-refs, risk notes. Fields above are the machine-readable
  # contract; `body` is the writer's narrative for Achilles.
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | object | yes | Per `contracts/schema-version.md`. `min_reader: 3.0.0` — readers on brief@2.x or older reject. |
| `id` | string (UUIDv7) | yes | Stable for the life of this brief. |
| `task_id` | string (UUIDv7) | yes | Parent task. Must resolve to an existing `task.yaml`. |
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
| `body` | string (multiline markdown) | yes | Free-form narrative. Preserves the brief template prose. |

## Lifecycle

See `state-machines/brief-lifecycle.md`. Summary:

```
draft → ready → dispatched → debriefed → archived
ready → superseded (rework replaces this brief)
dispatched → superseded (mid-flight replacement; rare)
```

Transitions emit `brief_state_changed` per `contracts/events.md`.

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
| 3.1.0 | 2026-04-22 | Full YAML shape — `reads` / `writes` / `acceptance` / `testability` promoted to structured arrays; markdown body kept as multi-line string. `min_reader: 3.0.0`. |
| 3.0.0 | 2026-04-15 (pre-2.6 envelope form) | Added `schema_version` object, `correlation_id`. |
| 2.x | pre-2026-04-15 | Markdown with YAML preamble; legacy. |

## Related

- `contracts/brief-formats/` — per-type template prose rendered into `body`.
- `state-machines/brief-lifecycle.md` — transitions.
- `schemas/task.md` — parent artifact.
- `schemas/debrief.md` — output produced when `state: debriefed`.
