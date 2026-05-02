---
name: debrief-writer-inventory
description: Active and diagnostic debrief writer inventory for Forge reliability issue #311.
type: contract
schema_version: 1
---

# Debrief Writer Inventory

Issue #311 invariant: active debrief producers write YAML only through `write_debrief_artifact`, landing under `plans/debriefs/<debrief-id>.yaml`. Legacy markdown and `plans/chanakya-inbox/*-debrief.*` are read/diagnostic-only surfaces.

## Active Writers

| Surface | Producer | Classification | Canonical target |
|---|---|---|---|
| Achilles task mode | `scripts/task-emit-debrief.sh` -> `scripts/lib-ledger.sh::write_debrief_artifact` | canonical | `plans/debriefs/<debrief-id>.yaml` |
| Achilles direct debrief | `achilles/modes/debrief.md` procedure, using the debrief schema contract | canonical | `plans/debriefs/<debrief-id>.yaml` |
| Achilles build/test/release modes | `achilles/modes/{build,test-suite,push-tf,app-store}.md` procedures, using the debrief schema contract | canonical | `plans/debriefs/<debrief-id>.yaml` |
| Apollo perf debriefs | `_shared/schemas/debrief.md` declares Apollo as a metrics-populated debrief author | canonical | `plans/debriefs/<debrief-id>.yaml` |

## Diagnostic-Only Legacy Readers

These scripts may mention legacy debrief paths, but they must not create active debrief artifacts there:

| Script | Classification | Purpose |
|---|---|---|
| `scripts/sweep-enumerate-debriefs.sh` | diagnostic-only legacy | Reports legacy markdown or chanakya-inbox debriefs with remediation text. |
| `scripts/migrate-ledger.sh` | migration-only legacy | Converts pre-2.6 `*-debrief.md` artifacts into YAML. |
| `scripts/archive-legacy-surfaces.sh` | cleanup-only legacy | Moves retired debrief-shaped inbox files into the legacy archive. |
| `scripts/backfill-legacy-yaml.sh` | migration-only legacy | Recovers YAML from archived legacy material. |
| `scripts/detect-edits.sh` | diagnostic-only legacy | Detects edits to processed legacy debriefs. |
| `scripts/analyze-collect.sh` | analysis-only legacy | Counts historical legacy debriefs for private reports. |
| `scripts/tests-pull-cases.sh` | canonical reader | Reads test cases from the linked debrief YAML only (`tests.added` + `tests.modified`); legacy markdown test artifacts are human-facing projections/import history, not fallback authority. |
| `scripts/verify-ledger.sh` | diagnostic-only legacy | Checks migration consistency against archived legacy files. |

## Regression Guard

`scripts/lint-debrief-writers.sh` blocks active scripts or mode prose that point a live debrief writer at:

- `plans/chanakya-inbox/*-debrief.md`
- `plans/chanakya-inbox/*-debrief.yaml`
- `plans/debriefs/*.md`
- `legacy_inbox_write_debrief`

The pre-commit hook runs the guard as Gate 2f. Allowed legacy readers are enumerated inside the linter with explicit classifications matching the table above.

## Runtime Cleanup

Run `scripts/sweep-enumerate-debriefs.sh` to list stranded legacy or misrouted debrief artifacts. Each diagnostic line includes a `remediation=` token:

- `archive-or-migrate-to-plans-debriefs-yaml` for markdown found under `plans/debriefs/`
- `move-to-plans-debriefs-yaml` for debrief-shaped files still under `plans/chanakya-inbox/`

For historical inbox markdown, run `scripts/archive-legacy-surfaces.sh` after confirming no active writer is producing new files. For migration recovery, use `scripts/migrate-ledger.sh` or `scripts/backfill-legacy-yaml.sh` so data is converted into canonical YAML instead of copied by hand.
