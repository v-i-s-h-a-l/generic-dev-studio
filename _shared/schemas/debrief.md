---
name: Debrief Schema
description: YAML shape for Achilles-authored debriefs under plans/debriefs/<debrief-id>.yaml. Replaces the markdown debrief format. Covers both task-mode (paired with a brief) and direct-debrief mode (from /achilles debrief with no brief).
type: reference
---

# Debrief Schema (`debrief@2.4.0`)

Per-debrief artifact written to `~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml`. Replaces the markdown debriefs that previously landed at `plans/chanakya-inbox/<task-id>-debrief.md`. Authored by Achilles in `task` mode (paired with a brief), Achilles in `debrief` mode (direct-debrief, no brief), or Apollo in any perf-mode (`metrics:` block populated, `executed_with.host` reflects Apollo's surface).

Version 2.0.0 was a breaking change from the legacy markdown format (`contracts/debrief-format.md`). Prose narratives are kept as strings inside typed fields so Chanakya's ingest path does not need NLP to locate "Decisions Made" or "Build Verification" — they are structured. Subsequent 2.x bumps (2.0.1, 2.0.2, 2.1.0, 2.2.0, 2.3.0, 2.4.0) are non-breaking additive changes; `min_reader: 2.0.0` keeps the entire active fleet compatible.

## Shape

```yaml
schema_version:
  name: debrief
  version: 2.4.0
  min_reader: 2.0.0
  deprecated_at: null
id: 0190f52a-79aa-7d02-8b88-33ce5fe65e66        # UUIDv7
task_id: 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11   # UUIDv7 | null
brief_id: 0190f52a-6e11-7c01-8a77-11a05a9e2b4c  # UUIDv7 | null
mode: task                                       # task | direct-debrief
state: emitted                                   # emitted | ingested | superseded
completed_at: 2026-04-22T12:40:51Z
executed_with:                                   # 2.1.0; multi-model accountability — populated from scripts/emit-agent-boot.sh data
  model_id: "claude-opus-4-7"                    # canonical model id (e.g. "claude-opus-4-7", "claude-sonnet-4-6", "gpt-5-codex")
  host: claude-code                              # claude-code | codex | <future-host>
  session_id: "session-42"                       # producer session id (matches agent-boot event)
  duration_s: 8246                               # integer seconds — wall-clock duration of the implementing session
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
    - title: "Filter preset row renders three presets"
      preconditions: "Open the editor with a photo selected."
      steps:
        - "Open the filter tray."
        - "Scroll through the first row of presets."
      expected: "Three default presets render and remain tappable."
    - "FilterPresetRowTests.testTappingPresetEmitsAnalytics"  # legacy title-only form still accepted
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
known_issues: []                                  # see "Concern entries" below — legacy strings or {id, text, category?, severity?}
follow_ups:
  - id: T271a-fu-1
    text: "Backend integration once endpoint lands — T027."
    category: backend-wiring
  - "Dark-mode contrast check in next review round."   # legacy string form still accepted
open_questions: []                                # for direct-debrief mode; typically empty in task mode
argus_review:
  status: approved                                # approved | flagged | blocked | skipped | not-invoked
  review_id: 0190f52a-7a11-7e03-8c99-44df6fd77a77 # null if not-invoked
  notes: null
report_state: done                                # done | done_with_concerns | blocked | needs_context — see contracts/worker-report.md
metrics: null                                     # 2.2.0; Apollo perf-mode only. Null for Achilles task / direct-debrief.
# Example of a populated Apollo metrics block (memory regression):
# metrics:
#   perf_mode: memory                             # memory | thermal | battery | cpu — mirrors brief.perf_mode
#   evidence_tier: 9                              # 9 (hard) | 1 (advisory; canonical anti-pattern only)
#   verdict: approved                             # approved | refused | advisory
#   cohort:
#     device: "iPhone 16 Pro"                     # Capture device — strict-9 cohort match enforced
#     os: "iOS 19.0"
#     build: "Release"
#   baseline:
#     artifact_path: "~/.dev-studio/<project>/perf/baseline-2026-04-27.trace"
#     artifact_kind: trace                        # trace | mxmetric | xcresult | signpost | energy-log | asc-perf
#     measure: "peak_resident_mb"
#     value: 412.3
#     unit: "MB"
#   observed:
#     artifact_path: "~/.dev-studio/<project>/perf/post-fix-2026-04-27.trace"
#     artifact_kind: trace
#     measure: "peak_resident_mb"
#     value: 287.1
#     unit: "MB"
#   delta:
#     absolute: -125.2
#     pct: -30.4
#     direction: improved                         # improved | regressed | unchanged
#   refusal: null                                 # Object when verdict: refused; null otherwise.
#   # When refusal is non-null:
#   #   reason: "Capture cohort mismatch — baseline iPhone 12, target iPhone 16 Pro"
#   #   required_action: "Re-capture baseline on target cohort"
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
| `tests` | object | yes | `{added, modified, skipped_because}`. `added` / `modified` accept legacy title strings or canonical case objects `{title, preconditions?, steps?, expected?}`. New task emits use objects so Chanakya can derive user-facing manifests from YAML only. `skipped_because` is null unless tests are intentionally deferred. |
| `testability` | object \| null | yes | Null for pure test-type tasks. Otherwise the testability report (SOLID, accessibility IDs, seams). |
| `build_gate` | enum | yes | `lsp-only` \| `full-green`. Drives Chanakya's build-debt counter per `schemas/build-debt.md`. |
| `build_debt_override` | boolean | yes | True iff `--ignore-build-debt` was used. |
| `debt` | object | yes | `{build, test_unit, test_ui, notes}`. Booleans indicate debt accrued on this run; `notes` optional string. |
| `performance` | array | yes | Optional perf observations. Empty array when none. |
| `key_learnings` | array of strings | yes | Non-obvious takeaways future sessions should know. |
| `known_issues` | array of concerns | yes | Unresolved items (e.g., user has not verified yet). Each concern is either a legacy string or `{id, text, category?, severity?}` — see "Concern entries" below. |
| `follow_ups` | array of concerns | yes | Future-task hints. Chanakya's debrief-ingest mode may mint tasks from these. Same shape as `known_issues`. |
| `open_questions` | array of strings | yes | Direct-debrief mode uses this for inline questions the user answered. Usually empty for task mode. |
| `argus_review` | object | yes | `{status, review_id, notes}`. Status `not-invoked` only valid when Argus was bypassed (xs-skip or direct-debrief). |
| `report_state` | enum \| absent | no | `done` \| `done_with_concerns` \| `blocked` \| `needs_context`. Worker-report contract — see `contracts/worker-report.md`. Absent in pre-2.0.2 debriefs; readers infer from other fields for back-compat. |
| `executed_with` | object \| absent | no | 2.1.0; `{model_id, host, session_id, duration_s}`. Producer identity for multi-model accountability. Absent in pre-2.1.0 debriefs; readers MUST tolerate absence and either join `events/<date>.jsonl` `agent_boot` records by `task_id` to fill the gap or treat the executor as unknown. Three of the four fields (`model_id`, `host`, `session_id`) are already produced by `scripts/emit-agent-boot.sh`; `duration_s` is computed from the matching `agent_session_completed` event timestamp delta. |
| `metrics` | object \| null | yes | 2.2.0; Apollo perf-mode only. Null for Achilles task / direct-debrief debriefs. Populated by Apollo when emitting a perf-mode debrief — carries strict-9 evidence (cohort, baseline, observed, delta, verdict) so Chanakya's ingest path can render perf outcomes without re-reading the underlying `.trace` / MXMetric artifact. Sub-shape documented inline with the example above; refusal subobject populated only when `verdict: refused`. |

## Concern entries

`known_issues[]` and `follow_ups[]` accept two shapes:

- **Legacy string** — `"Blend-mode approximations may diverge from IMGLY"`. Pre-2.3.0 debriefs use this exclusively. Readers MUST tolerate it. Inheritance validators synthesize an id at read time as `<legacy-task-id-or-debrief-id>-ki-<index>` (or `-fu-<index>`) where `<index>` is the 1-based array position.
- **Structured object** — `{id, text, category?, severity?}`. The `id` is stable across the artifact's lifetime (`<emitter-task-id>-ki-<n>` for known-issues, `-fu-<n>` for follow-ups). `category` is an optional short tag the inheritance validator (`scripts/validate-brief-inheritance.sh`) prefers as a grep probe over the full `text`. `severity ∈ {low, medium, high, critical}` is informational — no gate uses it today.

The structured form is the path forward (#162 — concern traceability). New emits should produce structured entries; the legacy form remains a back-compat carve-out for pre-2.3.0 debriefs that the studio does not rewrite. Producers MUST NOT mix shapes within a single array.

## Modes

### `task`

Invoked by `/achilles <task-id>` after merge. `task_id` + `brief_id` both set; `branch.merge_sha` populated.

### `direct-debrief`

Invoked by `/achilles debrief` (new in 2.6) with no task binding. `task_id` and `brief_id` both null. `branch` may be partially null if the direct session did not merge. `argus_review.status: not-invoked` is the common case.

Conversational invocation — the mode scans session transcript + working-tree diff, asks inline whether tests are needed, then emits this YAML. See `achilles/modes/debrief.md`.

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
| 2.4.0 | 2026-05-02 | Non-breaking: `tests.added[]` / `tests.modified[]` items may now be `{title, preconditions?, steps?, expected?}` objects. Legacy string form remains accepted; new task-mode emits use objects as the canonical source for test-manifest/test-flow generation (#335). |
| 2.3.0 | 2026-04-27 | Non-breaking: `known_issues[]` / `follow_ups[]` items may now be `{id, text, category?, severity?}` objects. Legacy string form remains accepted; no migration. Stable ids unblock `scripts/validate-brief-inheritance.sh` (#162 trimmed slice — silent-absorb gate at brief-write time). |
| 2.2.0 | 2026-04-27 | Non-breaking: add optional `metrics` block (`perf_mode`, `evidence_tier`, `verdict`, `cohort`, `baseline`, `observed`, `delta`, `refusal`) for Apollo perf-mode debriefs. Carries strict-9 evidence so Chanakya can render perf outcomes without re-reading artifacts (#235 Stage 5). Null for non-Apollo debriefs. |
| 2.1.0 | 2026-04-27 | Non-breaking: add optional `executed_with` block (`model_id`, `host`, `session_id`, `duration_s`) for multi-model accountability and A/B model-routing telemetry. Three fields already emitted by `scripts/emit-agent-boot.sh`; only the schema-side surface lands here (#247 Stage C deliverable 2). |
| 2.0.2 | 2026-04-23 | Non-breaking: add optional `report_state` field (4-state worker-report enum). Back-compat reader rule in `contracts/worker-report.md`. Drawn from obra/superpowers. |
| 2.0.1 | 2026-04-22 | Non-breaking: add `state` field (`emitted` \| `ingested` \| `superseded`). Missing `state` is read as `emitted` for back-compat. Motivated by direct-debriefs having no parent-task history to mark as ingested. |
| 2.0.0 | 2026-04-22 | Breaking: full YAML shape replaces markdown. `mode` field distinguishes task vs direct-debrief. `testability` becomes a typed object. `build_gate` / `build_debt_override` promoted to first-class fields. |
| 1.x | pre-2026-04-22 | Markdown with section headers (`contracts/debrief-format.md`); legacy. |

## Related

- `contracts/debrief-format.md` — legacy markdown format; kept for archive readability.
- `state-machines/brief-lifecycle.md` — `brief: debriefed` is the trigger for debrief emission.
- `schemas/task.md` / `schemas/brief.md` — parent artifacts.
- `schemas/review.md` — the Argus verdict referenced by `argus_review.review_id`.
- `achilles/modes/debrief.md` — the direct-debrief mode.
