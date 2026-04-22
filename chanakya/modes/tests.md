---
name: Chanakya Tests
description: Test-manifest (per-task checklist) + test-flow (journey-ordered walkthrough, with promote + diff modes). The two test-planning sub-commands are grouped because they are consulted together and share reads against processed debriefs and per-task test artifacts.
type: mode-pack
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: [briefs.json]
budget_tokens: 2500
reads:
  - plans/index.yaml                               # post-migration task + round + debrief index
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/debriefs/*.yaml                          # post-migration debrief artifacts (schema: _shared/schemas/debrief.md)
  - plans/rounds/*.yaml                            # previous-round retest linkage (schema: _shared/schemas/round.md)
  - plans/chanakya-master.md                       # legacy fallback until Commit H
  - plans/chanakya-inbox/<task-id>-tests.md        # legacy per-task test artifact (read-only surface)
  - plans/chanakya-inbox/processed/<task-id>-debrief.md  # legacy debrief read fallback until Commit H
  - plans/user-testing-rounds/user-testing-round<N>.md   # legacy round fallback until Commit H
  - journey-map.md                                 # optional project-root journey ordering
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
writes:
  - plans/rounds/<round-id>.yaml                   # post-migration canonical (schema: _shared/schemas/round.md, round@1.0.0)
  - plans/user-testing.md                          # per-task manifest (user-facing checklist surface)
  - plans/user-testing-rounds/user-testing-round<N>.md   # legacy round markdown during Phase 2.6 transition
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh after artifact writes
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Test-Manifest (`/chanakya test-manifest [--force]`)

Generate or refresh `~/.dev-studio/<project>/plans/user-testing.md` — the per-task checklist `/chanakya review-feedback` processes. Consult the `briefs.json` snapshot for the `done`-task list (5-minute freshness window; on stale or null `generated_at`, fall back to re-parsing `chanakya-master.md`).

## Step 1 — Dirty-state guard

Run `scripts/tests-dirty-state-check.sh <path-to-user-testing.md>`. Exit 2 means the file already carries user edits (checked boxes or Notes with content); refuse to regenerate and tell the user:

> "`user-testing.md` has pending feedback. Run `/chanakya review-feedback` to process it first, or re-run with `--force` to discard your edits and regenerate."

`--force` skips the guard.

## Step 2 — Scan candidate tasks

Run `scripts/tests-scan-candidates.sh`. One candidate id per line. Prefers post-migration index (tasks in `merged` + `user-verifying`); legacy fallback parses `chanakya-master.md` for `Status: done` rows. Empty output → nothing to test; return.

## Step 3 — Pull test cases

For each candidate id, run `scripts/tests-pull-cases.sh <task-id>`. Yields a YAML `cases:` block (title + preconditions + steps + expected) sourced from the debrief's `tests.added`/`tests.modified`, falling back to `<task-id>-tests.md` or the processed debrief's `## Test Cases` section. Empty output → record the task with a single "No test cases written — please inspect the debrief" placeholder.

## Step 4 — Write the manifest

Compose a YAML bundle with one task per candidate (id, title, debrief_path, cases) and pipe it to `scripts/tests-write-manifest.sh [--force]`. The script handles the dirty-state check, the atomic write, and the exact markdown format below (which `/chanakya review-feedback` depends on):

```markdown
# User Testing — <project>

Generated: <YYYY-MM-DD HH:mm IST>
Tasks awaiting verification: T013, T014, T015

Instructions:
- Tick `[ ]` → `[x]` for each case that passes.
- Write any failure or issue under the `Notes:` line below the case.
- When done, run `/chanakya review-feedback` to apply your edits to the master plan.

---

## T013 — <Title>
Debrief: `chanakya-inbox/processed/T013-debrief.md`

- [ ] Case 1: <preconditions> → <steps> → <expected result>
  Notes: 
```

## Step 5 — Report

"Generated user-testing.md with N tasks (T013, T014, T015). Open it, run through the cases, then `/chanakya review-feedback` when done."

---

# Mode: Test-Flow (`/chanakya test-flow [--force] [--round N] [--scope new|full|module <name>] [--smoke] [--diff N] [--promote]`)

Human-readable, journey-ordered single-sitting walkthrough. Unlike `test-manifest` (per-task, machine-parseable), test-flow is organized by **how you'd actually use the app**; rounds are numbered and never overwritten. `test-manifest` feeds `review-feedback`; test-flow is the human companion. `--promote` bridges them (Step 9).

## Flags

| Flag | Purpose |
|------|---------|
| `--round N` | Use round number N instead of auto-incrementing |
| `--force` | Overwrite an existing round file |
| `--scope new` | (default) Only `done` tasks — unverified work |
| `--scope full` | Include `done` + `verified` — full regression sweep |
| `--scope module <name>` | Only tasks touching a specific module/feature area |
| `--smoke` | Minimal smoke-test subset (one high-priority case per section + all retests, skip P2-only sections) |
| `--diff N` | Compare round N with the most recent completed round and emit a diff summary |
| `--promote` | After a round passes, generate a pre-checked `user-testing.md` so `review-feedback` can mark tasks verified |

## Step 1 — Determine round number

`--diff N` → Step 10. `--promote` → Step 9. `--round N` → use N. Otherwise scan `plans/user-testing-rounds/user-testing-round*.md`, take the highest N, use N+1 (start at 1 if none).

## Step 2 — Dirty-state guard & partial continuation

If `user-testing-round<N>.md` already exists, count `[x]` vs total checkboxes. Partial → ask "Continue testing round N, or generate a new round N+1?" (continue: exit; new: increment N). Untouched / fully-completed without `--force` → tell the user to pass `--force` or auto-increment. `--force` overwrites.

## Step 3 — Collect candidate tasks

Based on `--scope`. Reuse `scripts/tests-scan-candidates.sh` for `new`; filter its output or re-walk `chanakya-master.md` for `full` / `module`. Exit if zero matches: "No `done` tasks awaiting verification. Nothing to test."

## Step 4 — Identify re-tests

Cross-reference with the previous round file. A case is a **failure** if `Result:` has `[x] fail`, OR it's unchecked AND `Notes:` has non-empty content. Unchecked + empty Notes = **skipped** (not a failure — do not mark retests for these). For each failed case's parent task(s): if the task is still `done` in the current candidate set → `[R<prev> retest]`; if a follow-up fix (`Source: Txxx`) has status `done` → its cases get `[R<prev> retest]`.

## Step 5 — Organize by user journey

Group tasks into sections by module/feature area. Section ordering:

1. **Journey map** — if `journey-map.md` exists, use its defined section order. Match tasks to sections by keyword overlap between section names and: task title, brief title, debrief `## Files Changed` directory names, task `Skills:` field.
2. **Auto-infer** otherwise: cluster by file-path directory / skill tags / brief-title keywords; order foundational modules first (setup, core interaction), peripheral features last (export, infrastructure).
3. **Always include a Setup section** as section 0 (unnumbered):
   - [ ] Fresh build on simulator or device
   - [ ] Open a test item into the main workflow
   - [ ] Have secondary test data ready if applicable

Skip sections with zero cases.

## Step 6 — Build test cases

Within each section, pull cases via `scripts/tests-pull-cases.sh <task-id>` (same extraction as test-manifest). Rewrite each case as user-facing steps per `_shared/schemas/test-flow.md`:

```markdown
### 3.2 — <Case title>  [Txxx][Tyyy]  [R2 retest]  [critical]
Do: <user action>
Expect: <expected outcome>
Result: [ ] pass  [ ] fail
Notes:
Evidence:
```

**Severity tagging** (auto-inferred from parent task priority): P0 → `[critical]`, P1 → `[important]`, P2 → untagged.

**Performance cases.** If a case involves timing-sensitive behavior (rendering, transitions, loading), or the debrief has `## Performance` / key-learnings perf data, add `Perf baseline:` + `Timing: ___` fields.

**Smoke mode (`--smoke`):** per section, include only the highest-priority case + all retests; skip sections where every case is P2; add the header note "Smoke-test subset — run `/chanakya test-flow` without `--smoke` for the full walkthrough."

**Performance Checkpoints section.** Include a dedicated final section (before the crosswalk) for cross-cutting perf cases (cold launch, memory ceiling, undo chain, pipeline throughput) when any candidate task has perf data. Source baselines from the debrief; omit `Perf baseline:` when no data exists.

## Step 7 — Write the round artifact

Write the body (the rendered walkthrough — Setup, Sections, Performance Checkpoints, Crosswalk, Instructions) to a temp file, then:

```sh
scripts/tests-write-round.sh <round-number> <scope> <tasks-csv> <body-file>
```

Prints the minted round UUID. The script delegates to lib-ledger's `write_round_artifact` — YAML canonical + legacy markdown dual-write + `round_state_changed` event + index rebuild, all in one call.

## Step 8 — Report

> "Generated user-testing-round3.md with N sections, M test cases (K retests, J perf checkpoints) covering X tasks. Scope: new. Open it in your editor and walk through it on a fresh build."

`--smoke`:

> "Generated smoke-test round3.md with N sections, M cases (reduced from F full cases). Run without `--smoke` for comprehensive coverage."

## Step 9 — Promote mode (`--promote`)

Run `scripts/tests-promote-round.sh <round-number>` (defaults to the latest round if `--round N` is not given; the wrapper finds the target round YAML by `round_number`, falling back to the legacy markdown).

- Exit 3 means the gate failed — the script prints how many cases are still unchecked. Surface:
  > "Round N has K failures and J untested cases. Cannot promote — all cases must pass. Fix failures and re-test, or run `/chanakya intake` to file follow-up tasks for the failures."
- Exit 0 means `user-testing.md` was rewritten with passing cases pre-checked and any failures left unchecked + annotated. Report:
  > "Promoted round N → user-testing.md with X tasks pre-verified. Run `/chanakya review-feedback` to apply."

## Step 10 — Diff mode (`--diff N`)

Run `scripts/tests-diff-rounds.sh <round-a> <round-b>` where round-a is N and round-b is the comparison target (N+1 or the latest completed round). The script loads both (YAML preferred, legacy fallback), matches cases by id, and emits a markdown diff grouped into: regressions introduced, regressions fixed, A-only, B-only, unchanged. Perf cases with `timing_ms` on both sides land in a per-case delta table. Pipe stdout to the user directly; do not write to a file.
