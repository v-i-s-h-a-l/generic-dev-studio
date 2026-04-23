---
name: Debrief Schema
description: YAML shape for Achilles-authored debriefs under plans/debriefs/<debrief-id>.yaml. Replaces the markdown debrief format. Covers both task-mode (paired with a brief) and direct-debrief mode (from /achilles debrief with no brief).
type: reference
---

# Debrief Schema (`debrief@2.0.2`)

Per-debrief artifact written to `~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml`. Replaces the markdown debriefs that previously landed at `plans/chanakya-inbox/<task-id>-debrief.md`. Authored by Achilles in `task` mode (paired with a brief) or in `debrief` mode (direct-debrief, no brief).

Version 2.0.0 is a breaking change from the legacy markdown format (`contracts/debrief-format.md`). Prose narratives are kept as strings inside typed fields so Chanakya's ingest path does not need NLP to locate "Decisions Made" or "Build Verification" — they are structured.

## Shape

```yaml
schema_version:
  name: debrief
  version: 2.0.0
  min_reader: 2.0.0
  deprecated_at: null
id: 0190f52a-79aa-7d02-8b88-33ce5fe65e66        # UUIDv7
task_id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11   # UUIDv7 | null
brief_id: 0190f52a-6e11-7c01-8a77-11a05a9e2b4c  # UUIDv7 | null
mode: task                                       # task | direct-debrief
state: emitted                                   # emitted | ingested | superseded
completed_at: 2026-04-22T12:40:51Z
branch:
  worked_on: achilles/T001
  merged_into: feature/filter-presets
  merge_sha: a1b2c3d4e5f60718293a4b5c6d7e8f90
commits:
  - sha: a1b2c3d4e5f6
    message: "Add FilterPresetRow with three-preset scroll view"
  - sha: f1e2d3c4b5a6
    message: "Unit tests for FilterPresetViewModel"
diff_summary:
  files: 4
  added_lines: 187
  removed_lines: 12
decisions:
  - what: "Used LazyHStack instead of HStack for preset row."
    why: "Row may grow to 10+ presets once backend lands; lazy eval keeps scroll smooth."
  - what: "Pulled preset state into FilterPresetStore observable."
    why: "Two later screens need read access without re-deriving from viewmodel."
tests:
  added:
    - "FilterPresetRowTests.testRendersThreePresets"
    - "FilterPresetRowTests.testTappingPresetEmitsAnalytics"
  modified: []
  skipped_because: null                           # string when tests intentionally skipped, null otherwise
testability:
  solid_adherence: "FilterPresetStore injected via protocol; view stays pure."
  accessibility_ids: "Added in Project/Identifiers/FilterPresetIDs.swift — 3 IDs."
  test_seams: ["FilterPresetStoreProtocol"]
  architecture: "MVVM; no deviations."
  localization: "2 strings added via .localized, key namespace: filter.presets.*"
build_gate: lsp-only                              # lsp-only | full-green
build_debt_override: false
debt:
  build: false
  test_unit: false
  test_ui: false
  notes: null
performance: []                                   # array of {operation, timing, device} or []
key_learnings:
  - "LazyHStack rendering differs from HStack when inside a ScrollView; documented in code."
known_issues: []
follow_ups:
  - "Backend integration once endpoint lands — T027."
  - "Dark-mode contrast check in next review round."
open_questions: []                                # for direct-debrief mode; typically empty in task mode
argus_review:
  status: approved                                # approved | flagged | blocked | skipped | not-invoked
  review_id: 0190f52a-7a11-7e03-8c99-44df6fd77a77 # null if not-invoked
  notes: null
report_state: done                                # done | done_with_concerns | blocked | needs_context — see contracts/worker-report.md
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | object | yes | Per `contracts/schema-version.md`. |
| `id` | string (UUIDv7) | yes | |
| `task_id` | UUIDv7 \| null | yes | Null iff `mode: direct-debrief`. |
| `brief_id` | UUIDv7 \| null | yes | Null iff `mode: direct-debrief` or rework with no formal brief. |
| `mode` | enum | yes | `task` \| `direct-debrief`. Governs which fields are meaningful. |
| `state` | enum | yes | `emitted` \| `ingested` \| `superseded`. Lifecycle: Achilles writes `emitted`; Chanakya's debrief-ingest flips to `ingested` after minting follow-ups; a later debrief covering the same work may flip a prior one to `superseded`. The sweep filters on `state: emitted` to find unprocessed artifacts — no separate sidecar or event-log lookup required. |
| `completed_at` | RFC3339 UTC | yes | When the debrief was written. |
| `branch` | object | yes | `{worked_on, merged_into, merge_sha}`. Direct-debrief may set all three to null if no merge happened. |
| `commits` | array | yes | Per-commit `{sha, message}`. Empty array for no-commit direct-debrief sessions. |
| `diff_summary` | object | yes | `{files, added_lines, removed_lines}`. Integers ≥ 0. |
| `decisions` | array | yes | `{what, why}` tuples. Captures deviations + WHY notes. |
| `tests` | object | yes | `{added, modified, skipped_because}`. Arrays of test names; `skipped_because` null unless tests intentionally deferred. |
| `testability` | object \| null | yes | Null for pure test-type tasks. Otherwise the testability report (SOLID, accessibility IDs, seams). |
| `build_gate` | enum | yes | `lsp-only` \| `full-green`. Drives Chanakya's build-debt counter per `schemas/build-debt.md`. |
| `build_debt_override` | boolean | yes | True iff `--ignore-build-debt` was used. |
| `debt` | object | yes | `{build, test_unit, test_ui, notes}`. Booleans indicate debt accrued on this run; `notes` optional string. |
| `performance` | array | yes | Optional perf observations. Empty array when none. |
| `key_learnings` | array of strings | yes | Non-obvious takeaways future sessions should know. |
| `known_issues` | array of strings | yes | Unresolved items (e.g., user has not verified yet). |
| `follow_ups` | array of strings | yes | Future-task hints. Chanakya's debrief-ingest mode may mint tasks from these. |
| `open_questions` | array of strings | yes | Direct-debrief mode uses this for inline questions the user answered. Usually empty for task mode. |
| `argus_review` | object | yes | `{status, review_id, notes}`. Status `not-invoked` only valid when Argus was bypassed (xs-skip or direct-debrief). |
| `report_state` | enum \| absent | no | `done` \| `done_with_concerns` \| `blocked` \| `needs_context`. Worker-report contract — see `contracts/worker-report.md`. Absent in pre-2.0.2 debriefs; readers infer from other fields for back-compat. |

## Modes

### `task`

Invoked by `/achilles <task-id>` after merge. `task_id` + `brief_id` both set; `branch.merge_sha` populated.

### `direct-debrief`

Invoked by `/achilles debrief` (new in 2.6) with no task binding. `task_id` and `brief_id` both null. `branch` may be partially null if the direct session did not merge. `argus_review.status: not-invoked` is the common case.

Conversational invocation — the mode scans session transcript + working-tree diff, asks inline whether tests are needed, then emits this YAML. See `achilles/modes/debrief.md` (shipped in Commit G).

## Ingest

Chanakya's debrief-ingest mode reads both shapes uniformly (same schema, different `mode` value). No branching. The knowledge layer (Phase 2.7) indexes them identically.

## Migration note (2.6)

Legacy markdown debriefs at `plans/chanakya-inbox/<task-id>-debrief.md` migrate to `plans/debriefs/<debrief-id>.yaml` via `scripts/migrate-ledger.sh`. Transform:

1. Parses the section headers (`## Summary`, `## Commits`, `## Build Verification`, etc.).
2. Maps section contents into typed fields. Prose sections become list items split on `-` or newline.
3. Locates the `build_gate` / `build_debt_override` markers in the `## Build Verification` section.
4. Detects misfiled debriefs (any `*-debrief.md` file in `chanakya-inbox/` root) per Q20 and routes them to the correct destination with a migration-report entry.
5. Unparseable debriefs → `archive/2026-pre-2.6/unparseable/` with line-numbered report.

The 141 processed debriefs in `chanakya-inbox/processed/` are **copied as-is** to `archive/2026-pre-2.6/` per Q18 — not forward-ported. New consumers read only post-cutover YAML.

## History table

| Version | Landed | Changes |
|---|---|---|
| 2.0.2 | 2026-04-23 | Non-breaking: add optional `report_state` field (4-state worker-report enum). Back-compat reader rule in `contracts/worker-report.md`. Drawn from obra/superpowers. |
| 2.0.1 | 2026-04-22 | Non-breaking: add `state` field (`emitted` \| `ingested` \| `superseded`). Missing `state` is read as `emitted` for back-compat. Motivated by direct-debriefs having no parent-task history to mark as ingested. |
| 2.0.0 | 2026-04-22 | Breaking: full YAML shape replaces markdown. `mode` field distinguishes task vs direct-debrief. `testability` becomes a typed object. `build_gate` / `build_debt_override` promoted to first-class fields. |
| 1.x | pre-2026-04-22 | Markdown with section headers (`contracts/debrief-format.md`); legacy. |

## Related

- `contracts/debrief-format.md` — legacy markdown format; kept for archive readability.
- `state-machines/brief-lifecycle.md` — `brief: debriefed` is the trigger for debrief emission.
- `schemas/task.md` / `schemas/brief.md` — parent artifacts.
- `schemas/review.md` — the Argus verdict referenced by `argus_review.review_id`.
- `achilles/modes/debrief.md` — the direct-debrief mode (ships in Commit G).
