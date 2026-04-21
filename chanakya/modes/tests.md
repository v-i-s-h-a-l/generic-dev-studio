---
name: Chanakya Tests
description: Test-manifest (per-task checklist) + test-flow (journey-ordered walkthrough, with promote + diff modes). The two test-planning sub-commands are grouped because they are consulted together and share reads against processed debriefs and per-task test artifacts.
type: mode-pack
snapshots: [briefs.json]
budget_tokens: 4000
reads: []
writes: []
---

# Mode: Test-Manifest (`/chanakya test-manifest [--force]`)

Generate or refresh the consolidated user-testing file: `~/.dev-studio/<project>/plans/user-testing.md`.

Snapshot `snapshots/briefs.json` is consulted for the `done`-task list (5-minute freshness window; if `generated_at` is null or stale, fall back to re-parsing `chanakya-master.md` directly).

## Step 1 — Dirty-state guard

If `user-testing.md` already exists, scan it for user edits:
- Any line matching `- [x]` (checked box)
- Any `Notes:` line with non-empty content (i.e., content after the colon other than whitespace)

If either is present, **stop** and tell the user:

> "`user-testing.md` has pending feedback (N checked boxes, M notes). Run `/chanakya review-feedback` to process it first, or re-run with `--force` to discard your edits and regenerate."

Do not write anything. Return.

If `--force` was passed, skip the guard and overwrite.

## Step 2 — Scan master plan

Read `~/.dev-studio/<project>/plans/chanakya-master.md`. Collect every task whose status is `done` (not `verified`, not `in-progress`, not `briefed`). These are the manual-verification candidates.

## Step 3 — Pull test cases

For each candidate task `<task-id>`:
- Read `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-tests.md` if present.
- Otherwise, look for `## Test Cases` inside the processed debrief at `chanakya-inbox/processed/<task-id>-debrief.md`.
- If neither exists, record the task with a single "No test cases written — please inspect the debrief" placeholder.

## Step 4 — Write the manifest

Write to `~/.dev-studio/<project>/plans/user-testing.md` using the format below. Include the generation timestamp and the task list as a header.

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
Test artifact: `chanakya-inbox/T013-tests.md`

- [ ] Case 1: <preconditions> → <steps> → <expected result>
  Notes: 
- [ ] Case 2: <preconditions> → <steps> → <expected result>
  Notes: 

---

## T014 — <Title>
...
```

## Step 5 — Report

"Generated user-testing.md with N tasks (T013, T014, T015). Open it, run through the cases, then `/chanakya review-feedback` when done."

---

# Mode: Test-Flow (`/chanakya test-flow [--force] [--round N] [--scope new|full|module <name>] [--smoke] [--diff N] [--promote]`)

Generate a human-readable, journey-ordered single-sitting test walkthrough. Unlike `test-manifest` (per-task, machine-parseable, feeds `review-feedback`), test-flow is organized by **how you'd actually use the app** and produces numbered round files that are never overwritten.

**Relationship to test-manifest:** Independent commands. `test-manifest` is the machine-parseable per-task checklist that `review-feedback` processes. `test-flow` is the human companion — the user walks through it, then either (a) fills out the per-task `test-manifest` and runs `review-feedback`, or (b) reports findings via `/chanakya intake`. The `--promote` flag bridges the two (see Step 9).

## Flags

| Flag | Purpose |
|------|---------|
| `--round N` | Use round number N instead of auto-incrementing |
| `--force` | Overwrite an existing round file |
| `--scope new` | (default) Only `done` tasks — unverified work |
| `--scope full` | Include `done` + `verified` tasks — full regression sweep |
| `--scope module <name>` | Only tasks touching a specific module/feature area |
| `--smoke` | Generate a minimal smoke-test subset (one high-priority case per section + all retests, skip P2-only sections) |
| `--diff N` | Instead of generating a round, compare round N with the most recent completed round and output a diff summary |
| `--promote` | After the user fills out a round and everything passes, auto-generate a pre-checked `user-testing.md` from the round results so `review-feedback` can mark tasks verified |

## Step 1 — Determine round number

- If `--diff N` is passed, skip to **Step 10** (diff mode).
- If `--promote` is passed, skip to **Step 9** (promote mode).
- If `--round N` is passed, use N.
- Otherwise, scan `~/.dev-studio/<project>/plans/user-testing-rounds/` for existing `user-testing-round*.md` files, find the highest N, and use N+1. If none exist, start at 1.

## Step 2 — Dirty-state guard & partial continuation

If `user-testing-round<N>.md` already exists:

1. **Check for partial completion.** Scan for checked boxes `[x]` and total checkboxes. If some are checked but not all:
   > "Round N is partially completed (K/M cases checked). Continue testing round N, or generate a new round N+1?"
   Wait for user response. If they say continue, exit without changes. If they say new, increment N and proceed.

2. **If fully untouched or fully completed**, and `--force` is not passed:
   > "Round N already exists. Use `--force` to overwrite or omit `--round` to auto-increment."
   Return.

3. If `--force` is passed, overwrite.

## Step 3 — Collect candidate tasks

Based on `--scope`:

- **`new`** (default): From `chanakya-master.md`, collect every task with status `done` (not `verified`). If zero candidates, exit: "No `done` tasks awaiting verification. Nothing to test."
- **`full`**: Collect all tasks with status `done` or `verified`. Exit if zero.
- **`module <name>`**: Collect `done` (or `done` + `verified` if combined with `full`) tasks whose files-changed, brief title, or skill tags match the module name. Match against debrief `## Files Changed` paths, brief titles, and task `Skills:` field. Exit if zero matches.

## Step 4 — Identify re-tests

Cross-reference with the previous round's file (if it exists in `user-testing-rounds/`):

- Parse each case in the prior round. A case is a **failure** if: the `Result:` line has `[x] fail`, OR the checkbox is unchecked AND `Notes:` has non-empty content.
- A case is **skipped** (not a failure) if: unchecked with empty `Notes:`.
- For each failed case's parent task(s) `[Txxx]`:
  - If the task itself is still `done` and appears in the current candidate set → mark it `[R<prev> retest]`.
  - If a follow-up fix task (with `Source: Txxx`) has status `done` → mark the fix task's cases `[R<prev> retest]`.
- Do NOT mark retests for merely skipped cases.

## Step 5 — Organize by user journey

Group tasks into sections by module/feature area. The section ordering is determined as follows:

1. **Check for journey map.** If `~/.dev-studio/<project>/journey-map.md` exists, use its defined section order. Format:

   ```markdown
   # Journey Map
   1. Setup
   2. Core Canvas
   3. Filter Module
   ...
   ```

   Each line maps a section name. Tasks are matched to sections by keyword overlap between the section name and: task title, brief title, debrief `## Files Changed` directory names, and task `Skills:` field.

2. **Auto-infer if no journey map.** Group tasks by analyzing:
   - File paths from debrief `## Files Changed` — cluster by directory/module
   - Skill tags on the task
   - Brief title keywords
   Order sections by dependency: foundational modules first (setup, core interaction), peripheral features last (export, infrastructure). Number sections sequentially.

3. **Always include a Setup section** as section 0 (unnumbered in output) with:
   - [ ] Fresh build on simulator or device
   - [ ] Open a test item into the main workflow
   - [ ] Have secondary test data ready if applicable

Skip sections with zero cases.

## Step 6 — Build test cases

Within each section, pull test cases from:
- `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-tests.md` (if present)
- Or the processed debrief's `## Test Cases` block at `chanakya-inbox/processed/<task-id>-debrief.md`
- If neither exists, create a placeholder: "No test cases written — inspect the debrief manually"

Rewrite each case as user-facing steps:

```markdown
### 3.2 — <Case title>  [Txxx][Tyyy]  [R2 retest]  [critical]
Do: <user action>
Expect: <expected outcome>
Result: [ ] pass  [ ] fail
Notes:
Evidence:
```

**Severity tagging:** Auto-infer from parent task priority:
- P0 → `[critical]`
- P1 → `[important]`
- P2 → (no tag)

**Performance cases:** If the test case involves timing-sensitive behavior (rendering, transitions, loading), or the debrief mentions performance data in `## Key Learnings` or a `## Performance` section, add performance fields:

```markdown
### 3.4 — <Case title>  [Txxx]  [perf]
Do: <user action>
Expect: <expected outcome, including timing threshold>
Perf baseline: <value from debrief, if available>
Result: [ ] pass  [ ] fail
Timing: ___
Notes:
Evidence:
```

**Smoke mode (`--smoke`):** When active, for each section:
- Include only the highest-priority case (by parent task priority, then first case)
- Always include all retest cases `[R<prev>]`
- Skip entire sections where all cases are P2
- Add a header note: "Smoke-test subset — run `/chanakya test-flow` without `--smoke` for the full walkthrough."

## Step 7 — Write the file

Ensure `~/.dev-studio/<project>/plans/user-testing-rounds/` directory exists. Write to `user-testing-round<N>.md` following the format at `~/.claude/skills/_shared/schemas/test-flow.md`.

**Performance Checkpoints section:** Include a dedicated final section (before the crosswalk) for cross-cutting perf cases when any candidate task has performance-related test cases or debrief data (cold launch, memory ceiling, undo chain, pipeline throughput). Source baselines from debrief `## Key Learnings` or `## Performance` sections. If no data exists, omit `Perf baseline:` — the user fills in the first measurement.

## Step 8 — Report

> "Generated user-testing-round3.md with N sections, M test cases (K retests, J perf checkpoints) covering X tasks. Scope: new. Open it in your editor and walk through it on a fresh build."

If `--smoke` was used:

> "Generated smoke-test round3.md with N sections, M cases (reduced from F full cases). Run without `--smoke` for comprehensive coverage."

## Step 9 — Promote mode (`--promote`)

When `--promote` is passed (no other flags except optionally `--round N`):

1. Determine which round to promote. If `--round N`, use that. Otherwise, use the latest round file.
2. Read the round file. Parse all cases.
3. **Gate check:** Every case must have `[x] pass` checked. If any case has `[x] fail` or is unchecked:
   > "Round N has K failures and J untested cases. Cannot promote — all cases must pass. Fix failures and re-test, or run `/chanakya intake` to file follow-up tasks for the failures."
   Return.
4. Collect all unique task IDs from `[Txxx]` tags across all passing cases.
5. Generate `~/.dev-studio/<project>/plans/user-testing.md` in the standard test-manifest format, with all cases pre-checked `[x]`:
   ```markdown
   # User Testing — <project>
   
   Generated: <YYYY-MM-DD HH:mm IST>  (promoted from round <N>)
   Tasks awaiting verification: <task list>
   ...
   
   ## Txxx — <Title>
   - [x] Case 1: ...
     Notes: passed in round N
   ```
6. Report:
   > "Promoted round N → user-testing.md with X tasks pre-verified. Run `/chanakya review-feedback` to apply."

## Step 10 — Diff mode (`--diff N`)

When `--diff N` is passed, compare round N with the next completed round (N+1, or the latest round if N+1 doesn't exist).

1. Read both round files. If either doesn't exist, error with the missing path.
2. Parse all cases from both rounds. Match cases by their `[Txxx]` task tags + case title.
3. Classify changes:
   - **Regressions:** pass in round N → fail in round N+K (or pass → untested)
   - **Fixes confirmed:** fail in round N → pass in round N+K
   - **New cases:** present in round N+K but not in round N
   - **Dropped cases:** present in round N but not in round N+K (task was verified between rounds)
   - **Unchanged:** same result in both rounds
4. **Performance comparison:** For `[perf]` cases present in both rounds, compare `Timing:` values:
   - Flag regressions >20% slower with ⚠️
   - Flag improvements >20% faster with ✓
   - Show delta as absolute and percentage
5. Output to stdout (not a file):

```markdown
## Test-Flow Diff: Round N → Round M

### Regressions (pass → fail)  ⚠️
- 3.2 — Filter grid aspect ratio [T118]: was passing, now fails
  Notes from round M: "Grid cells stretched on landscape"

### Fixes Confirmed (fail → pass)  ✅
- 1.4 — Action bar styling [T105]: was failing in round N, now passes

### Performance Delta  📊
| Case | Round N | Round M | Delta |
|------|---------|---------|-------|
| 3.4 — Filter apply (48MP) | 0.6s | 0.5s | -17% ✓ |
| N.1 — Cold launch | 1.8s | 2.4s | +33% ⚠️ |
| N.2 — Memory peak | 380MB | 520MB | +37% ⚠️ |

### New Cases (M only)
- 5.1 — Crop rotation sync [T130]

### Dropped (N only, now verified)
- 2.3 — Canvas zoom [T102]

### Summary
- Total cases: N=38, M=42
- Regressions: 1
- Fixes: 2
- Perf regressions: 2 of 4 checkpoints
```
