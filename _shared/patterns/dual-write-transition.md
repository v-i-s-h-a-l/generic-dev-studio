---
name: Dual-Write Transition Pattern
description: Rule for Phase 2.6 transition writers — every mutation of a brief/task/round/release/debrief/review artifact MUST write the YAML artifact AND update the legacy counterpart. AND-not-OR. Fail loud on partial failure. Flag flips to yaml-only at Commit H.
type: reference
---

# Dual-Write Transition Pattern

Phase 2.6 introduced structured YAML artifacts under `plans/{tasks,briefs,rounds,releases,debriefs,reviews}/*.yaml`. Until Commit H (legacy retirement) the pre-existing markdown surfaces (`plans/chanakya-master.md`, inbox debrief files, the Release Log section) still have readers. During this window every writer is a **dual writer**.

This file exists because T218a drifted: a writer updated the legacy brief markdown, skipped the YAML artifact, and the two surfaces diverged silently. Issue #76 caught it post-hoc via `verify-ledger.sh`. The fix is prose-level (mode packs) and script-level (`scripts/lib-ledger.sh` helpers).

> **Not to be confused with:** the *migration-time* dual-write that `PHASE-2-6-PLAN.md` §6.2 explicitly dropped. That was about preserving write-availability during the migration transform itself — unnecessary because the project quiesces during migration. This pattern is about *post-migration* writers that must keep both surfaces consistent until Commit H retires legacy.

## Rules

1. **AND, not OR.** Every mutation writes the YAML artifact **and** updates the legacy counterpart in the same logical operation. Prose like "write YAML, or update legacy if YAML unavailable" is a bug.

2. **Order: YAML first, legacy second.** YAML is the future source of truth; write it first so a crash after step 1 leaves the system biased toward the post-transition shape. Readers that prefer YAML see consistent data; legacy-only readers see the pre-mutation state, which is better than a partially-mutated future state.

3. **Partial-failure is loud.** If the YAML write succeeds but the legacy write fails (disk full, permission change, concurrent lock), emit a `dual_write_partial` event with `{subject_kind, subject_uuid, legacy_path, reason}` and exit non-zero (exit code `3`). Do not swallow. The next sweep picks up the event and surfaces it.

4. **Index rebuild is the final step.** `plans/index.yaml` regenerates from the YAML layer. Index rebuild must run *after* both writes succeed. Batch via `WITHHOLD_INDEX=1` + `flush_index` when a mode pack performs N mutations in sequence; single rebuild at the end.

5. **Flag-controlled flip (#245 A.3, shipped).** The helpers in `scripts/lib-ledger.sh` honor `DUAL_WRITE_MODE` env: `yaml-only` (default post-A.3) skips the legacy step; `both` re-enables dual-write as an escape hatch for future migrations. The default flip stopped dual-writing without editing every mode pack.

6. **Dry-run preserves both sides.** Under `DRY_RUN=1` per `dry-run.md`, log **two** `DRY-RUN write` lines — one YAML, one legacy — so dry-run output captures the full intent.

7. **Idempotency key covers both surfaces; dedupe checks both.** The key per `_shared/contracts/idempotency.md` is computed from the logical mutation, not the per-file write. One key, two writes, one event. The producer-side dedupe check (`idempotency.md` §3) must consult **both** sinks — if the YAML matches but the legacy counterpart does not, the retry re-attempts the legacy write (not a full no-op). Otherwise a partial failure becomes sticky: the YAML-only dedupe short-circuits retries while legacy stays stale.

## Scope

Applies to every writer that mutates any of these Phase 2.6 artifact kinds:

- `tasks` — `plans/tasks/<uuid>.yaml` + legacy `chanakya-master.md` rows
- `briefs` — `plans/briefs/<uuid>.yaml` + legacy brief markdown in inbox
- `rounds` — `plans/rounds/<uuid>.yaml` + legacy round markdown
- `releases` — `plans/releases/<uuid>.yaml` + legacy `Release Log` section
- `debriefs` — `plans/debriefs/<uuid>.yaml` + legacy inbox debrief markdown
- `reviews` — `plans/reviews/<uuid>.yaml` + legacy review markdown

`plans/index.yaml` is a derived view — rebuilt, never dual-written.

## Mode-pack integration

Mode packs that mutate any of the above declare in frontmatter:

```yaml
transition_notes: _shared/patterns/dual-write-transition.md
writes: [<kinds>]
```

Compliance is grep-checkable: every mode pack with a `writes:` entry touching the scope list above must carry the `transition_notes:` pointer. Audit pass in Phase 2.6.5 commit 2 establishes the baseline; from then on REVIEW R9 catches additions.

## Script-level enforcement

`scripts/lib-ledger.sh` exposes `write_task_artifact`, `write_brief_artifact`, etc. Each helper:

1. Composes the YAML payload.
2. Writes YAML under `plans/<kind>/<uuid>.yaml` (resolved via `lib-paths.sh`).
3. If `DUAL_WRITE_MODE=both` (default), writes the legacy counterpart via `legacy_master_plan_*` / `legacy_inbox_*` / `legacy_release_log_*` helpers.
4. On partial failure, emits `dual_write_partial` and exits 3.
5. Returns only when both writes succeeded (or DRY_RUN skipped both).

Mode-pack prose calls the helper once per logical mutation. Prose does not know about "two files" — that's a script-level concern.

## Related

- `_shared/patterns/dry-run.md` — dry-run logs two write lines, one per surface
- `_shared/contracts/events.md` — `dual_write_partial` event shape
- `_shared/contracts/idempotency.md` — one key covers both writes
- `_shared/primitives/file-locations.md` — canonical YAML + legacy paths
- Issue #76 — incident that motivated this pattern
- Phase 2.6.5 commits 2 (audit) and 3 (lib-ledger.sh helpers)
