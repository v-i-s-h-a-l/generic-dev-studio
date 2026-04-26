---
issue: 245
phase: A.1
date: 2026-04-27
purpose: Reader audit for Commit H flip — enumerate every consumer of the legacy markdown surfaces (chanakya-master.md, chanakya-tasks/, chanakya-inbox/<task>-debrief.md) so A.3 (DUAL_WRITE_MODE=yaml-only default) and A.4 (archive legacy paths) can land safely.
closes_partial: 76
---

# #245 Stage A.1 — Reader audit

Walks every consumer of the legacy Phase-2.5 markdown surfaces and classifies it. Output is a go/no-go map for A.3 (default-flip) and A.4 (archive). Folds in the work that was scoped for #76 (dual-write audit).

## Scope

In-scope legacy paths (the ones #245 retires):

- `plans/chanakya-master.md`
- `plans/chanakya-tasks/<task-id>-*.md`
- `plans/chanakya-inbox/<task-id>-debrief.md`
- `plans/chanakya-inbox/processed/<task-id>-debrief.md`
- Build/release/test-suite debrief variants under `plans/chanakya-inbox/` (e.g. `tf-*-debrief.md`, `release-*-debrief.md`, `build-*-debrief.md`, `test-suite-*-debrief.md`)

Explicitly **out of scope** (kept post-flip per `_shared/primitives/file-locations.md`):

- `plans/chanakya-inbox/assets/` — feedback attachments live here. The migration didn't touch them; sweep-janitor's `orphan-assets` mode + ingest mode's attachment download both write here.
- `plans/chanakya-inbox/<task-id>-tests.md` — test-case artifacts. Migration didn't scope them; `task-write-test-cases.sh` still writes here, `tests-pull-cases.sh` still reads here, `chanakya/test-manifest` consumes them.
- `plans/chanakya-inbox/feedback-attachments/<feedback-id>/` — Slack ingest mirror; legacy alias retained during 2.6 transition (separate decision from #245).
- `plans/chanakya-inbox/design-report-<date>.md`, `product-report-<date>.md` — Commit F kept these locations.

A.4 must scope the archive sweep to **debrief-shaped** entries, not the whole `chanakya-inbox/` directory.

## Classification key

| Class | Meaning | A.3/A.4 implication |
|---|---|---|
| **W** writer | Writes to a legacy path. Already gated by `_lw_dual_write_enabled()` → safe under A.3 (becomes no-op) → retired in A.5. | A.3-safe; A.5 cleanup |
| **W!** unguarded writer | Writes to a legacy path **without** the dual-write gate. Will keep writing under A.3 unless fixed. | **Must fix before A.3** |
| **R-live** live runtime reader | Reads a legacy path for a runtime decision with no YAML alternative. | **Must migrate before A.3** |
| **R-fallback** transition fallback reader | Tries YAML first; falls back to legacy when YAML missing. Already emits `legacy_artifact_read`. Fail-safe to empty when both absent. | A.3-safe; A.4 makes the legacy branch unreachable for new projects (correct outcome) — branches deletable in A.5 |
| **R-archive** archival/analysis reader | Reads pre-migration archive paths for analysis/backfill tools. Not a runtime decision. | A.3-safe; survives A.4 if it points at `archive/2026-pre-2.6/`, otherwise re-routes there |
| **W-migration** one-shot migration writer | `scripts/migrate-ledger.sh` etc. — deliberately writes to legacy *as input*, not as live state. | Untouched |
| **OOS** out-of-scope path | Touches `chanakya-inbox/assets/` or `<task>-tests.md` — kept post-flip. | Untouched |
| **DOC** documentation/prose | Mentions the legacy path in user-facing prose, contracts, README, mode-pack frontmatter. | Mass cleanup post-A.4 (non-blocking for A.3) |
| **TEST** test fixture | Test data referencing legacy paths (e.g. migrate-ledger test fixture). | Untouched |

## Findings

### Live runtime readers — block A.3 until migrated

| File | Line | Class | Notes |
|---|---|---|---|
| `scripts/sweep-threshold-actions.sh` | 28 | **R-live** | Reads `## Build Debt` Counter directly from `chanakya-master.md`. **Build-debt counter exists nowhere else today** — it's not in `plans/index.yaml` (no `build_debt:` field; see "Terminology correction" below) and there is no `scripts/render-master-plan.sh` to project it from YAML. Today this script reads master-plan because that is literally the only place the data lives. **A.3 prerequisite: ship Shape B's `scripts/render-master-plan.sh`** (named in lean-arc memory as "the only writer post-flip, wired into `sweep-ingest.sh`") — once it exists, the master-plan file becomes a render-only projection and this script's read is fine; alternatively, promote `build_debt` to a first-class `plans/index.yaml` field and re-point the script there. Without one of those, A.3 breaks build-debt threshold logic. |
| `scripts/next-task-id.sh` | 51 | **R-live** | Greps master-plan + legacy-tasks-dir for max numeric suffix when allocating next `T<n>` id. Has yaml `TASKS_DIR` source as a sibling — already covers post-migration ids. After A.4 archives master-plan, the master + legacy-dir branches return zero hits for new projects (no harm). For migrated projects, ids are already covered by yaml. **A.3-safe** with one caveat: `legacy_artifact_read` is **not** emitted from this script; it should be, so the fallback is observable like other R-fallback consumers. One-liner fix. |

### Unguarded writers — block A.3 until gated

| File | Line | Class | Notes |
|---|---|---|---|
| `scripts/sweep-ingest.sh` | 413 | **W!** | Writes `Released in: TF-<n>` annotation directly to `chanakya-master.md` per task. Bypasses `_lw_dual_write_enabled()`. Comment at line 401 admits "the lib-ledger helper doesn't exist yet." After A.3, projects with `DUAL_WRITE_MODE=yaml-only` still get this write — not OK. **Action before A.3:** wrap the write in `if _lw_dual_write_enabled; then …; fi` (line 244 helper is in scope when `lib-ledger.sh` is sourced). Better: extract to a `legacy_master_plan_annotate_release()` helper in `lib-ledger.sh` for parity with the other 5 dual-writer sites. |

### Writers — already gated, safe under A.3, retire in A.5

| File | Sites | Class | Notes |
|---|---|---|---|
| `scripts/lib-ledger.sh` | 383, 619, 687, 802, 1002 | **W** | All 5 sites gated by `_lw_dual_write_enabled()`. A.3 flips default; A.5 simplifies the helpers and removes the `dual_write_partial` event for current artifact kinds. Line 1025 (`legacy_master_plan_path()`) stays — `scripts/render-master-plan.sh` will still write to that path post-flip (the file becomes a render-only projection per Shape B). |

### Transition fallback readers — A.3-safe, branches deletable in A.5

| File | Line(s) | Class | Notes |
|---|---|---|---|
| `scripts/status-fallback-loaders.sh` | 38 | **R-fallback** | Tries `query-plans.sh` first. Falls back to master via `chanakya-snap.sh briefs`. Emits `legacy_artifact_read{domain:briefs, reason:plans_index_missing}`. Fail-safe to `{"tasks":[],"total":0,"source":"empty"}`. |
| `scripts/chanakya-snap.sh` | 77, 222 | **R-fallback** | `produce_briefs` + `produce_debt` parse master-plan; emit empty/null snapshot when missing. Used as the underlying fallback by `status-fallback-loaders`. |
| `scripts/task-load-spec.sh` | 85 | **R-fallback** | Tries YAML brief by `legacy_task_id`; falls back to `chanakya-tasks/<id>-*.md`. Emits `legacy_artifact_read{domain:briefs, reason:no_yaml_brief_for_legacy_id}`. |
| `scripts/tests-scan-candidates.sh` | 48 | **R-fallback** | Tries `index.yaml`-driven `emit_from_index`; falls back to master-plan `Status: done` rows. Emits `legacy_artifact_read{domain:candidates}`. |
| `scripts/achilles-worker.sh` | 185 | **R-fallback** | "At-least-one-present" debrief check during 2.6 transition. Tries legacy first, then YAML. After A.4 the legacy path will never exist; the elif branch suffices. **A.5 cleanup:** invert order (YAML primary, legacy removed). |
| `scripts/sweep-enumerate-debriefs.sh` | 98+ | **R-fallback** | Walks `plans/chanakya-inbox/<task>-debrief.md` for the sweep enumerator. Has a YAML loop above this in the same file. Branch becomes dead code after A.4 (the directory contents are archived). **A.5 cleanup:** delete the legacy-walk block. |
| `scripts/tests-pull-cases.sh` | 7-9 | **R-fallback** | Reads YAML `tests.added`/`tests.modified` first; falls back to `chanakya-inbox/processed/<task>-debrief.md` for old debriefs. (The `<task>-tests.md` source is OOS.) Emits `legacy_artifact_read`. |

### Archival readers — survive A.4 unchanged or with archive-root re-route

| File | Line | Class | Notes |
|---|---|---|---|
| `scripts/migrate-ledger.sh` | 309, 367, 633, 818 | **W-migration** | One-shot migration tool. Reads pre-2.6 markdown as *input*, writes YAML. Untouched by A.3/A.4. |
| `scripts/backfill-orphan-debriefs.sh` | 6, 53, 91 | **R-archive** | Sweep tool that compares processed-debriefs against master-plan rows. After A.4, point `MASTER` and the inbox scan at `archive/2026-pre-2.6/plans/…`. One-line edit. |
| `scripts/analyze-collect.sh` | 66, 69 | **R-archive** | `DEBRIEFS_DIR_LEGACY="$PROJECT_ROOT/plans/chanakya-inbox/processed"`. Used by analysis/event-log work. After A.4, re-point at `archive/2026-pre-2.6/plans/chanakya-inbox/processed`. |
| `scripts/detect-edits.sh` | 18, 212 | **R-archive** | Comment + `legacy_inbox` var for pre-2.6 debrief mtime scan. Re-point post-A.4. |
| `scripts/verify-ledger.sh` | 84, 105 | **R-archive** | Already points at `$ARCHIVE_ROOT/plans/chanakya-tasks/`. **No change needed** — already on the post-archive path. |

### Out-of-scope (kept post-flip)

| File | Line | Class | Notes |
|---|---|---|---|
| `scripts/sweep-janitor.sh` | 191 | **OOS** | `chanakya-inbox/assets/` — attachment storage, retained per file-locations.md. |
| `scripts/task-write-test-cases.sh` | 5 (comment + write @ line 64) | **OOS** | Writes `<task-id>-tests.md` — test artifacts, retained per file-locations.md. |

### Tests / fixtures

| File | Class | Notes |
|---|---|---|
| `scripts/test-fixtures/migrate-ledger/migrate-roundtrip.sh` | **TEST** | Synthesizes legacy fixture data to drive the migration tool. Untouched. |
| `tests/fixtures/leaky-detector/clean-task-ids.md` | **TEST** | Mentions legacy paths in fixture text. Untouched. |

### Documentation surfaces — mass cleanup after A.4

These are not runtime consumers; they describe the legacy paths in prose, frontmatter declarations, or contracts. Each carries `# legacy ... until Commit H` annotations that become obsolete the moment A.4 lands. Cleanup is mechanical and can be a single batch commit after A.4.

**Mode-pack frontmatter** (every chanakya/achilles mode that touches state):

- `chanakya/modes/{brief,brief-review,compact,feedback,feedback-reports,inbox-sweep,ingest,intake,review,ship,status,sweep-debt,sync-slack,tests,update,verify}.md` — 16 files. Each lists `chanakya-master.md` / `chanakya-tasks/` / `chanakya-inbox/` as legacy fallback or dual-write target in `reads:` / `writes:` blocks, with a "Phase 2.6 transition" prose paragraph.
- `achilles/modes/{app-store,build,group,next,push-tf,task,test-suite}.md` — 7 files. Same shape: legacy fallback + dual-write target + transition note.
- `argus/modes/spec-compliance.md` — 1 file. `chanakya-tasks/<task-id>-*.md` listed as legacy brief fallback.

Cleanup pattern per file: drop legacy entries from `reads:` / `writes:`, delete the "Phase 2.6 transition" paragraph, simplify any "Post-migration: X. Legacy fallback: Y." prose to just "X."

**Contracts / schemas / patterns** (the rule-and-shape surface):

- `_shared/contracts/brief-formats/impl-brief.md` — brief authoring contract; says "Write to chanakya-tasks/...". Replace with reference to `_shared/schemas/brief.md` (YAML).
- `_shared/contracts/debrief-format.md` — describes the legacy markdown debrief format. Decision needed: keep as historical reference, or delete + redirect to `_shared/schemas/debrief.md`. Recommendation: delete; the YAML schema is canonical post-flip.
- `_shared/contracts/events.md:115` — `debrief_edited` definition references `chanakya-inbox/processed/`. Re-word in terms of YAML debrief mtime under `plans/debriefs/`.
- `_shared/contracts/message-contract.md:46` — example uses legacy path. Update example.
- `_shared/contracts/read-write-decls.md` — example block uses legacy paths (lines 24, 48, 52-53). Update examples.
- `_shared/patterns/capability-manifest.md:33-34` — example payload uses legacy paths. Update example.
- `_shared/patterns/dual-write-transition.md` — entire pattern describes the dual-write window. **Keep** per #245 issue body ("kept as a primitive for future migrations") but mark the document as historical/reference, not active guidance.
- `_shared/primitives/agent-comms-boundary.md:42, 148, 165` — already references "until #245 lands" / "warn until Commit H, block thereafter." Just delete the warn-tier transitional notes; the boundary doc keeps its `B4` rule (now block-tier).
- `_shared/schemas/brief.md:9, 93` — historical pointers ("Replaces the markdown briefs that previously lived at..."). Keep one-line historical note; drop the full migration paragraph.
- `_shared/schemas/debrief.md:9, 125, 130, 133` — same shape. Keep one-line historical note.
- `_shared/state-machines/brief-lifecycle.md:48` — example payload uses `brief_path: ...chanakya-tasks/T001-impl.md`. Update example to YAML path.

**Generated manifest** (downstream of mode-pack edits):

- `_shared/schemas/capability-manifest.json` — aggregated from mode-pack `reads:`/`writes:` blocks. Will refresh automatically when the mode packs above are cleaned. No direct edits.

**READMEs / repo-level docs:**

- `chanakya/README.md` — multiple references in walkthroughs (lines 257, 280, 411) and the project layout diagram (lines 582-593). Walkthrough text describes Achilles writing to `chanakya-inbox/<task>-debrief.md`; the layout diagram still shows the legacy directory tree. Rewrite walkthroughs to describe YAML artifacts; replace layout diagram with the post-flip `plans/{tasks,briefs,debriefs,...}/` shape.
- `chanakya/snapshots/README.md:21-22` — table column "Source of truth" lists `chanakya-master.md`. Replace with `plans/index.yaml` (or whatever the post-flip producer reads).
- `chanakya/docs.html` — lines 982 (script command), 1288 (build-debt prose), 1556 (file tree row), 1564, 1569 (file tree dirs). Update file-tree section + build-debt prose; the `backfill-orphan-debriefs.sh` line 982 callout becomes "writes to archive" post-flip.
- `scripts/README.md:41` — stuck-state-detection prose mentions the legacy debrief path as the existence check. Worker uses YAML now (per the audit of `achilles-worker.sh:185`); update prose.
- `README.md:263` — bootstrap instruction `mkdir -p ~/.dev-studio/$PROJECT/plans/chanakya-inbox/processed`. Becomes `plans/debriefs` (or just delete — `bootstrap.sh` should own directory creation, not the README).
- `PHASE-2-6-PLAN.md`, `ANALYSIS.md` — historical plan/analysis docs. Leave as-is (they describe the migration in past tense; references are accurate to that moment).

## Documentation accuracy issue (fix in this audit)

`_shared/primitives/file-locations.md:84` says of the legacy directories:

> "Kept for historical reads on migrated projects ... **They are no longer written to.**"

This is **wrong today** — `lib-ledger.sh` defaults `DUAL_WRITE_MODE=both`, so every active writer (5 lib-ledger sites + the unguarded sweep-ingest write at line 413) is currently writing to the legacy paths on every run. The "no longer written to" wording should describe the **post-#245 state**, not today's state. Fixed in this commit (one-line wording change).

## Terminology correction (added 2026-04-27 post-write)

The first draft of this audit used "Commit G" as shorthand for "the still-pending master-plan-from-YAML regenerator." That was wrong — Phase 2.6 Commit G shipped in full (G1=`084acb0`, G2=`3d5ca39`, G3a–d=`b0412e6`/`dd27252`/`1acd6f1`/`0e41d3b`), and Commit H also landed (`72012f2` "cutover: canonical YAML layout primary, legacy preserved"). The mode-pack prose at `achilles/modes/build.md:27` ("the `build_debt` section that Commit G's master-plan regenerator emits from `plans/index.yaml`") is **aspirational, not factual** — that regenerator was never built and `plans/index.yaml` has no `build_debt` field. The actual prerequisite is Shape B's `scripts/render-master-plan.sh`, which the lean-arc memory names but does not yet exist. A.3 cannot flip until Shape B's writer (or an equivalent YAML-native source for `build_debt`) lands. **Cleanup task:** sweep mode packs that say "lands in Commit G" / "Commit G's regenerator" — Commit G has shipped; the prose should say "lands when `scripts/render-master-plan.sh` ships (Shape B, #245 prerequisite)" or be cut entirely.

## A.3 readiness checklist

Before A.3 can flip the default safely:

1. **Ship Shape B's `scripts/render-master-plan.sh`** (or promote `build_debt` to `plans/index.yaml`) — the load-bearing prerequisite for `sweep-threshold-actions.sh`. Without this, A.3 breaks build-debt threshold logic. Likely a Stage A.0 / A.1.5 of #245 itself, since the Shape B writer is named in the same arc.
2. **Wrap `scripts/sweep-ingest.sh:413`** in `_lw_dual_write_enabled` (or extract to a lib-ledger helper). The W! finding above. Half-day.
3. **Add `legacy_artifact_read` emission** to `scripts/next-task-id.sh` so the master-plan read is observable like the other R-fallback consumers. One-liner.
4. **Soak** (evidence-bound, not calendar-bound) per A.2: production run with `DUAL_WRITE_MODE=yaml-only` on user's project until **all** exit conditions hold — ≥30 task cycles completed end-to-end (each exercises brief → debrief → review writer paths), ≥1 release ceremony executed, ≥1 sweep / janitor / analyze run, and zero `legacy_artifact_read` emissions of unaccounted-for domain. **Expected allowlist (full):** `tests` (out-of-scope), `briefs` (status-fallback-loaders + task-load-spec), `debriefs` (sweep-enumerate-debriefs + detect-edits), `candidates` (tests-scan-candidates), `build_debt` (sweep-threshold-actions), `next_task_id` (next-task-id). Any new `domain:` value = missed reader from A.1, fix forward, then continue soak. At ~10–20 task cycles/day on this repo, exits in roughly 3–5 days of normal usage rather than a calendar month. **Retroactive scan against turnip-ios's full dual-write history (2026-04-15→04-27, scripts/soak-status.sh):** 31 task cycles, 6 releases, 26 sweeps, three observed domains (`briefs=33, debriefs=22, next_task_id=2`) — all in allowlist, zero unaccounted. Numerical thresholds met from history; A.3 unblocked by evidence as of 2026-04-27.

## A.4 readiness checklist

Before A.4 archives the legacy paths:

1. **A.5 cleanup of dual-write helpers** (or schedule for immediately after A.4). A.4 archives the directories; the `_emit_dual_write_partial` calls in `lib-ledger.sh` become reachable-but-no-op writes that would surface as `dual_write_partial` events forever.
2. **Re-point archival readers** (`backfill-orphan-debriefs.sh`, `analyze-collect.sh`, `detect-edits.sh`) at `archive/2026-pre-2.6/plans/…` instead of `plans/…`. One-line edits.
3. **Scope the archive sweep** to debrief-shaped files only — leave `chanakya-inbox/assets/` and `chanakya-inbox/<task>-tests.md` in place per OOS findings.
4. **Migrate `chanakya-snap.sh produce_briefs/produce_debt` to YAML-primary.** Found during A.2 retroactive verification: snap reads `chanakya-master.md` only (zero references to `tasks/*.yaml` / `index.yaml` / `build-debt.yaml`). Safe under A.3 because `render-master-plan.sh` keeps the master a fresh derived view; A.4 archives that file and snap's snapshot output silently degrades to `{"tasks":[],"total":0,"note":"no master plan found"}`. Migration: read `plans/index.yaml` for the brief list (same shape as `status-fallback-loaders.sh` does), read `plans/build-debt.yaml` for `produce_debt` (replaces awk-on-master-plan parse). Tracked as a separate issue.

## A.5 cleanup punchlist

After A.3 + A.4 land, the following can be deleted:

- `scripts/lib-ledger.sh`: 5 dual-writer call sites (lines 383, 619, 687, 802, 1002), `_lw_dual_write_enabled()` (236), `_emit_dual_write_partial()` (245). Helper for legacy master-plan path (1025) **stays** — render-only projection still uses it.
- `scripts/sweep-ingest.sh`: line 413 block (the now-gated annotation write).
- `scripts/sweep-enumerate-debriefs.sh`: legacy walk block (line 98+).
- `scripts/achilles-worker.sh`: legacy debrief check (line 185), invert to YAML-only.
- All R-fallback "legacy fallback" branches in `task-load-spec.sh`, `tests-scan-candidates.sh`, `status-fallback-loaders.sh`, `chanakya-snap.sh produce_briefs/produce_debt`, `tests-pull-cases.sh`. Each script keeps the YAML primary path; the legacy elif goes away.
- All "Phase 2.6 transition" paragraphs from the 24 mode-pack files (16 chanakya + 7 achilles + 1 argus).
- `legacy_artifact_read` event class — no callers remain (after the cleanups above). Decision: delete from `_shared/contracts/events.md`, or keep for future migrations behind a note?
- `dual_write_partial` event class — same decision.

## Coverage notes

- **Total file hits**: 65 files across the repo, 242 reference lines.
- **Live runtime readers needing migration**: 2 (sweep-threshold-actions, next-task-id).
- **Unguarded writers needing fix**: 1 (sweep-ingest:413).
- **R-fallback (gated, A.3-safe)**: 7 scripts.
- **R-archive (re-point post-A.4)**: 4 scripts.
- **OOS / migration / test**: 4 scripts.
- **Mode packs / contracts / READMEs / docs.html**: ~30 doc surfaces, all mechanical cleanup.

## Open questions for the user

1. **Shape B `render-master-plan.sh` ownership.** It's the load-bearing prerequisite for A.3 (the build-debt counter has no other home). Lean-arc memory names it but doesn't assign it. Should it ship as Stage A.0 of #245 (this arc), or is it a separate issue (e.g. inside #251 queries umbrella, or a fresh spin-off)? Recommend Stage A.0 of #245 — the dependency is too tight to split across arcs.
2. **A.5 timing relative to A.4.** Should A.5 (helper cleanup) ride in the same PR as A.4 to avoid `dual_write_partial` events firing into nothing? Recommend yes — the two cleanups are coupled.
3. **`legacy_artifact_read` and `dual_write_partial` event classes.** Delete in A.5 or keep as primitive for future migrations?
