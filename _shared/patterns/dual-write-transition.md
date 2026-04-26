---
name: Dual-Write Transition Pattern
description: Pattern primitive for migrating an artifact kind from one write surface to another via a temporary dual-write window. The Phase 2.6 → YAML migration that motivated this primitive closed under #245 (A.4 archive + A.5 retire); rules below describe the pattern shape so future migrations can reuse it.
type: reference
---

# Dual-Write Transition Pattern

A **dual-write transition** moves an artifact kind from one write surface (markdown, log file, db table) to another (YAML schema, structured store, …) without a hard cutover. Every writer briefly maintains both sides, partial failures fail loud, and a single env flag flips the default once readers have migrated. The Phase 2.6 → YAML migration was the first instance; the pattern is preserved for future migrations of the same shape.

This file exists because the first naive attempt at the migration drifted: a writer updated the legacy brief markdown, skipped the YAML artifact, and the two surfaces diverged silently. Issue #76 caught it post-hoc via `verify-ledger.sh`. The fix was prose-level (mode packs) and script-level (`scripts/lib-ledger.sh` helpers).

> **Not to be confused with:** the *migration-time* dual-write (write-availability during the transform itself) — unnecessary because projects typically quiesce during migration. This pattern is about *post-migration* writers maintaining both surfaces during the readers-migrating window.

## Rules

1. **AND, not OR.** Every mutation writes the YAML artifact **and** updates the legacy counterpart in the same logical operation. Prose like "write YAML, or update legacy if YAML unavailable" is a bug.

2. **Order: YAML first, legacy second.** YAML is the future source of truth; write it first so a crash after step 1 leaves the system biased toward the post-transition shape. Readers that prefer YAML see consistent data; legacy-only readers see the pre-mutation state, which is better than a partially-mutated future state.

3. **Partial-failure is loud.** If the YAML write succeeds but the legacy write fails (disk full, permission change, concurrent lock), emit a `dual_write_partial` event with `{subject_kind, subject_uuid, legacy_path, reason}` and exit non-zero (exit code `3`). Do not swallow. The next sweep picks up the event and surfaces it.

4. **Index rebuild is the final step.** `plans/index.yaml` regenerates from the YAML layer. Index rebuild must run *after* both writes succeed. Batch via `WITHHOLD_INDEX=1` + `flush_index` when a mode pack performs N mutations in sequence; single rebuild at the end.

5. **Flag-controlled flip + archive cutover (Phase 2.6 instance: #245 A.3 → A.4/A.5).** The pattern uses an env flag (here `DUAL_WRITE_MODE`) so a single edit flips every writer's default once readers have migrated, without touching mode packs. After the flag soaks (#245 A.2) and flips (#245 A.3), the legacy surfaces archive to `.legacy-archive/` (#245 A.4) and the dual-write call sites + helper functions are deleted entirely (#245 A.5). The env flag itself becomes inert — kept as a no-op for back-compat or removed in the cleanup commit. For the Phase 2.6 instance, `DUAL_WRITE_MODE` is no longer consulted post-A.5; the legacy_*_helpers are stub-fail (exit 9).

6. **Dry-run preserves both sides.** Under `DRY_RUN=1` per `dry-run.md`, log **two** `DRY-RUN write` lines — one YAML, one legacy — so dry-run output captures the full intent.

7. **Idempotency key covers both surfaces; dedupe checks both.** The key per `_shared/contracts/idempotency.md` is computed from the logical mutation, not the per-file write. One key, two writes, one event. The producer-side dedupe check (`idempotency.md` §3) must consult **both** sinks — if the YAML matches but the legacy counterpart does not, the retry re-attempts the legacy write (not a full no-op). Otherwise a partial failure becomes sticky: the YAML-only dedupe short-circuits retries while legacy stays stale.

## Scope (historical — Phase 2.6 instance)

Applied to every writer that mutated these Phase 2.6 artifact kinds during the dual-write window:

- `tasks` — `plans/tasks/<uuid>.yaml` + legacy `chanakya-master.md` rows
- `briefs` — `plans/briefs/<uuid>.yaml` + legacy brief markdown in inbox
- `rounds` — `plans/rounds/<uuid>.yaml` + legacy round markdown
- `releases` — `plans/releases/<uuid>.yaml` + legacy `Release Log` section
- `debriefs` — `plans/debriefs/<uuid>.yaml` + legacy inbox debrief markdown
- `reviews` — `plans/reviews/<uuid>.yaml` + legacy review markdown

`plans/index.yaml` was a derived view — rebuilt, never dual-written. After #245 A.4/A.5 closed the window, only the YAML side is written; the legacy markdown surfaces are under `plans/.legacy-archive/`.

## For future migrations using this pattern

Stand up a new dual-write transition by:

1. Pick a single writer-library entry point (mirror `scripts/lib-ledger.sh`'s shape) — every writer routes through there.
2. Add an env flag (`DUAL_WRITE_MODE` was reused; a future migration can pick its own) that gates the legacy-side write at one consultation point.
3. Implement the legacy helpers as discrete functions named `legacy_<noun>_<verb>` so retirement is a single grep + delete pass later.
4. Add `transition_notes: _shared/patterns/dual-write-transition.md` to every mode pack `writes:` declaration in scope so reviewers and lints can find the active migration.
5. Plan the close-out as four phases: A.1 reader audit → A.2 evidence-bound soak → A.3 flag flip → A.4/A.5 archive + delete.

`dual_write_partial` and `legacy_artifact_read` event classes (per `_shared/contracts/events.md`) are kept available for new migrations even though no current writer emits them.

## Related

- `_shared/patterns/dry-run.md` — dry-run logs two write lines, one per surface
- `_shared/contracts/events.md` — `dual_write_partial` + `legacy_artifact_read` event shapes
- `_shared/contracts/idempotency.md` — one key covers both writes
- `_shared/primitives/file-locations.md` — canonical YAML + archived legacy paths
- Issue #76 — incident that motivated this pattern
- Issue #245 — full Phase 2.6 close-out (A.0 → A.5)
- Phase 2.6.5 commits 2 (audit) and 3 (lib-ledger.sh helpers)
