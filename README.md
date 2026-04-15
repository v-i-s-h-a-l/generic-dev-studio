# Generic Dev Studio

A two-agent system for Claude Code. **Chanakya** plans the work; **Achilles** executes it in an isolated git worktree, self-reviews, gates on a green build, and hands off follow-ups without ever touching your uncommitted changes.

Built around an iOS/SwiftUI project (Turnip) but the orchestration layer is codebase-agnostic.

All per-project artifacts live under `~/.dev-studio/<project>/` — outside `~/.claude/` so neither agent trips self-mod permission prompts.

---

## TL;DR

```
/chanakya                       # describe features → get a master plan
/chanakya brief T001            # generate a self-contained worker brief
/achilles T001                  # execute (XS/S: lsp-only, M/L: full build; merges immediately)
/achilles T001 --wait           # execute, block up to 10 min for user feedback
/achilles T001 --force-build    # override size-driven gate; run full xcodebuild
/achilles                       # direct mode — free-form task, no brief required
/achilles build                 # on-demand build check at HEAD; auto-bisects on red
/chanakya status                # see what's in flight + what awaits verification + build debt
/chanakya test-manifest         # consolidate all done-but-unverified tasks into a testable file
/chanakya review-feedback       # apply your edits to the test manifest back to the master plan
```

Default Achilles run merges immediately and logs a "manual verification" follow-up. XS/S tasks skip `xcodebuild` (LSP-only) and accumulate **build debt** — at counter=6 Chanakya files a `TBUILD` P0 check; at 12 new briefs are refused. Run `/achilles build` any time: green resets the counter, red auto-bisects to name the breaking commit and files a P0 fix. Achilles never self-selects the next task — the user (or Chanakya) always drives.

---

## What's in the Repo

```
chanakya/
  SKILL.md      # manager agent — intake, briefing, status, PRD review, inbox sweep,
                #                  test-manifest, review-feedback
  README.md     # long-form manager docs with examples
  docs.html     # interactive docs page (rendered in browser)

achilles/
  SKILL.md      # worker agent — isolated execution pipeline (see below)

commands/
  chanakya-help.md   # /chanakya-help — opens docs.html in browser
```

---

## Install

### Option 1 — symlink (recommended, tracks repo updates)

```bash
ln -s "$PWD/chanakya"  ~/.claude/skills/chanakya
ln -s "$PWD/achilles"  ~/.claude/skills/achilles
ln -s "$PWD/commands/chanakya-help.md" ~/.claude/commands/chanakya-help.md
```

### Option 2 — copy

```bash
cp -r chanakya/ ~/.claude/skills/chanakya/
cp -r achilles/ ~/.claude/skills/achilles/
cp commands/chanakya-help.md ~/.claude/commands/
```

### One-time directories (per project)

Achilles auto-creates `~/.dev-studio/<project>/{worktrees,locks,derived-data}` on first run. The plans folder is typically created by your first `/chanakya` invocation. If you want them up front:

```bash
PROJECT=$(basename "$(git rev-parse --show-toplevel)")
mkdir -p ~/.dev-studio/$PROJECT/plans/chanakya-tasks
mkdir -p ~/.dev-studio/$PROJECT/plans/chanakya-inbox/processed
mkdir -p ~/.dev-studio/$PROJECT/worktrees
mkdir -p ~/.dev-studio/$PROJECT/locks
mkdir -p ~/.dev-studio/$PROJECT/derived-data
```

### Permissions

Add to `~/.claude/settings.json` under `permissions.allow`:

```
"Read(~/.dev-studio/**)",
"Write(~/.dev-studio/**)",
"Edit(~/.dev-studio/**)",
"Bash(git *)",
"Bash(xcodebuild:*)",
"Bash(mkdir:*)"
```

`~/.dev-studio/` sits outside `~/.claude/` on purpose — it sidesteps the self-mod permission guard so Achilles and Chanakya can read/write their artifacts unattended.

---

## How It Works

### Chanakya — the manager

1. **Intake** — paste features, Figma links, PRD bullets, or crash logs. Chanakya turns them into tasks with IDs (`T001`, `T002`, …), priorities (P0/P1/P2), complexity, and skill assignments.
2. **Brief generation** — for plan-worthy tasks, Chanakya writes a **self-contained** brief that inlines Figma specs, codebase pointers, acceptance criteria, and architectural constraints. A worker reads *only* that brief.
3. **Inbox sweep** — every invocation (and optionally every 10 min in the background) processes debriefs from `chanakya-inbox/`: marks tasks `done`, records commit hashes, auto-creates and briefs any follow-up tasks, stamps each with a `Source:` pointer to its parent.
4. **PRD delta** — `/chanakya review` diffs an updated PRD against the master plan and flags which tasks need rework.
5. **Test manifest** — `/chanakya test-manifest` consolidates every `done` (not yet `verified`) task's test cases into one editable file (`user-testing.md`). You tick boxes and add notes; `/chanakya review-feedback` promotes passing tasks to `verified` and creates follow-up tasks from failures.
6. **Build-debt tracking** — every inbox sweep updates the `## Build Debt` counter in the master plan using each debrief's `build_gate:` field. Warn@6 auto-files `TBUILD-<n>` (P0 check task); block@12 refuses new briefs. A passing manual build check (green) resets the counter to 0; a failing one files a P0 fix task naming the bisected breaking commit.
7. **Retrospective** — when all tasks for a feature are `verified`, Chanakya compiles a feature memory into `~/.claude/projects/.../memory/` so the knowledge survives across sessions.

### Achilles — the worker

Achilles runs an 11-step pipeline. The flow is the same whether the task comes from a Chanakya brief or from a direct-mode instruction:

```
1. Load spec                — read brief or ask the user; parse --wait /
                              --force-build / --ignore-build-debt flags
1.5 Build-debt gate         — read ## Build Debt from master plan.
                              silent ≤5 / warn 6-11 / block ≥12 (or red-
                              build outstanding). Block refuses the task
                              unless --ignore-build-debt or it's a TBUILD.
2. Claim the task           — set master plan status to in-progress
3. Isolate                  — compute PROJECT slug from git toplevel;
                              git worktree add from committed HEAD
                              (uncommitted changes stay untouched)
4. Implement                — small logical commits against the brief
5. Self-review              — one iteration via the `simplify` skill
6. Build gate (size-driven) — XS/S (size from brief, no escalation
                              triggers) → swift-lsp diagnostics only,
                              emit build_gate=lsp-only.
                              M/L or escalation triggers (import/public/
                              protocol/async/generics/Package.swift/
                              new-or-deleted files) → full xcodebuild,
                              serialized via mkdir lock, per-task
                              -derivedDataPath. --force-build escapes
                              size-selection up to full-green.
7. Write test cases         — standalone artifact + debrief section
8. Optional wait            — default: no wait, "manual verification"
                              follow-up logged. --wait: prompt; auto-
                              merge after 600s via ScheduleWakeup.
9. Commit + merge --no-ff   — merge into ORIG_BRANCH locally, serialized
   + worktree remove          via a second mkdir lock. Clean merges also
   + derived-data cleanup     rm -rf the per-task DerivedData. Failures
                              preserve branch + DerivedData for debugging
10. Debrief + short summary — debrief includes ## Build Verification
                              block (build_gate value). Chanakya's Step 0
                              updates the debt counter from this field.
11. (+900s) surface follow-ups — on wake, scan master plan for every
                                 task whose Source: is this task, list
                                 them with acceptance criteria, then idle
```

### Build mode (`/achilles build`)

On-demand verification, one command, fully automatic:

```
B1. Compute Covers: range from ## Build Debt (last-green SHA → HEAD).
    Fast-path no-op if HEAD == last-green SHA.
B2. Isolate detached-HEAD worktree at build-<timestamp>/.
B3. Full xcodebuild at HEAD (same lock as normal Step 6).
B4a. GREEN → write manual-build-check debrief, cleanup worktree +
     DerivedData, print summary. Chanakya's next sweep resets counter.
B4b. RED  → git bisect <last-green>..HEAD, re-acquiring lock per step,
     reusing DerivedData to keep SPM warm. Capped at 6 bisect steps.
     Debrief names the breaking commit + suspect files. Artifacts
     retained. Chanakya's next sweep files the P0 fix task.
```

Key guarantees:

- Your uncommitted working-tree changes in the main checkout are **never** disturbed — Achilles always branches from committed HEAD into `~/.dev-studio/<project>/worktrees/<task-id>/`.
- A red build is **never** merged. Branch + DerivedData are left alive for inspection.
- Merge conflicts are **never** force-resolved. Achilles stops and surfaces them; branch + DerivedData retained.
- **Builds are serialized across parallel Achilles instances** via a per-project `mkdir` lock. Designed for 6–10 workers running in parallel without SPM-cache / module-cache races.
- **Merges are serialized too** via a second per-project lock — `.git/index.lock` contention, branch-checkout races, and `$ORIG_BRANCH` tip movement are all handled.
- **DerivedData lives per-task** at `~/.dev-studio/<project>/derived-data/<task-id>/` (explicit `-derivedDataPath`). Cleaned up on clean merge, retained on any failure.
- Achilles never self-picks the next task. Control returns to the user after each completion.

---

## Examples

### Example 1 — Full feature loop (default: batch-friendly, no wait)

```
you: /chanakya
you: We need an Export flow — HEIF toggle, share sheet, saved-to-photos
     confirmation. Figma: figma.com/design/abc123?node-id=1:42171
     Also a FAB redesign (P1). And there's a crash on empty state in
     CollageGridView — fix that directly.

chanakya: Drafted 3 tasks.
  T001 — Export flow (P0, L, plan-worthy)
  T002 — FAB redesign (P1, M, plan-worthy)
  T003 — CollageGridView empty-state crash (direct — send to Achilles)
  Start briefing T001?

you: yes, brief T001 and T002

chanakya: Briefs saved to chanakya-tasks/. Kick off both in parallel?

you: /achilles T001
you: /achilles T002     (separate session / background)

achilles[T001]: Branching achilles/T001 from main@3c239a5.
                Worktree at ~/.dev-studio/turnip-ios/worktrees/T001/.
                [implements → simplify → serialized build → green]
                Merged achilles/T001 into main (local, --no-ff, b41f2aa).
                Worktree + DerivedData cleaned up. Debrief dropped.
                **T001 done.** Test cases at T001-tests.md.
                [15 min later] Follow-ups from T001 ready. Chanakya
                created T014 — Verify HEIF export in low-storage scenario.

you: /chanakya test-manifest
chanakya: Generated user-testing.md — 3 tasks awaiting verification
          (T001, T002, T003). Tick the boxes when you've tested.

you: [opens user-testing.md in your editor, runs through cases]
     [checks all boxes for T001 and T003; T002 fails case 2 —
      writes "FAB overlaps status bar on iPhone SE"]

you: /chanakya review-feedback
chanakya: Processed user-testing.md:
          - T001 → verified
          - T002 → 1 follow-up created (T004 — Fix FAB status-bar overlap)
          - T003 → verified
          Archived. Generate a fresh manifest when more tasks complete.
```

### Example 2 — Interactive single-task (opt into wait)

```
you: /achilles T005 --wait

achilles: [implements, self-reviews, builds green]
          T005 implementation is done and the build is green.
          Test cases at T005-tests.md. Reply within 10 min with
          feedback, or I'll auto-merge.

you: [runs through cases] looks good, ship it

achilles: Merged. **T005 done.**
```

If you don't reply within 10 min, the `ScheduleWakeup(600s)` wake fires, Achilles stamps "no reply within window" into the debrief, and merges anyway. The wait never hangs forever.

### Example 3 — Direct-mode bug fix

```
you: /achilles
you: The CollageGridView crashes when the user opens an empty album.
     Stack trace: ... Array index out of range at line 142.

achilles: Reproduced from the trace. Guard against empty sections
          before the stride call.
          [patches, self-reviews, builds green, writes test cases,
           merges immediately — default no-wait]
          Done. 1 commit, 1 file changed. Test cases at
          direct-a1b2c3d-tests.md. Debrief dropped for Chanakya.
```

### Example 4 — Red build blocks merge

```
achilles: [Step 6] xcodebuild failed — missing symbol `ExportHEIFOptions`.
          Fix attempt 1: added import → still fails, SPM package not listed.
          Surfacing: this looks like a missing dependency. Not merging.
          Branch achilles/T009 is left in place. DerivedData retained at
          ~/.dev-studio/turnip-ios/derived-data/T009/ for inspection.
```

### Example 5 — Parallel fleet + test manifest rhythm

```
you: /achilles T010      (5 more in other sessions...)
     /achilles T011
     /achilles T012
     /achilles T013
     /achilles T014
     /achilles T015

[all 6 run in parallel; each acquires the build lock in turn;
 each acquires the merge lock in turn; each cleans up its
 DerivedData after its own clean merge]

chanakya: [background sweep] Processed T010..T015 — 6 done.
          2 follow-ups briefed (T020, T021).

you: /chanakya test-manifest
chanakya: Generated user-testing.md — 6 tasks awaiting verification.

[you test, edit, run /chanakya review-feedback — 5 verified,
 1 failure becomes T022]
```

### Example 6 — Background sweep

```
you: /chanakya
chanakya: Enable background inbox sweep every 10 min for this session?
          (y/n)
you: y
chanakya: Will sweep every 600s. [silent unless something processed]
          [10 min later] Processed T005 — done, 1 follow-up briefed (T018).
```

---

## When to Use What

| Situation                                 | Tool                                  |
|-------------------------------------------|---------------------------------------|
| New feature with Figma                    | `/chanakya` → `/achilles`             |
| Multi-file refactor                       | `/chanakya` → `/achilles`             |
| Bug fix / crash                           | `/achilles` (direct mode)             |
| One-file UI tweak                         | `/achilles` (direct mode)             |
| Running 6–10 tasks in parallel            | `/achilles T00X` × N (default no-wait)|
| Want to watch a single task merge         | `/achilles T001 --wait`               |
| Force full build on a small task          | `/achilles T001 --force-build`        |
| Verify main is green on demand            | `/achilles build`                     |
| Build debt blocked you (counter ≥ 12)     | `/achilles build` (or complete the red-build fix task) |
| Must ship despite block (rare, risky)     | `/achilles T001 --ignore-build-debt`  |
| PRD changed mid-feature                   | `/chanakya review`                    |
| Check what's in flight (+ debt state)     | `/chanakya status`                    |
| Batch-test completed work                 | `/chanakya test-manifest` → edit → `/chanakya review-feedback` |
| Nudge Chanakya to re-scan inbox           | `/chanakya` (Step 0 runs on entry)    |

---

## Adapting to Other Projects

The core orchestration is project-agnostic — `<project>` slug is derived automatically from the basename of the main repo's git toplevel.

To port to a non-iOS stack:

1. **Swap the skill registry** in `chanakya/SKILL.md` — replace the Swift/SwiftUI skill table with your stack's equivalents.
2. **Swap the build command** in `achilles/SKILL.md` Step 6 — replace `xcodebuild -derivedDataPath ...` with `cargo build --target-dir ...`, `pnpm build --dist ...`, `go build -o ...`, whatever applies. Keep the per-task output-dir convention so cleanup stays trivial.
3. **Drop Figma if unused** — remove the MCP calls from Brief Generation Step 3.
4. **Update project memory path** in both SKILL.md files (`~/.claude/projects/.../memory/`).

The pipeline (isolate → implement → self-review → green build → optional wait → merge-back → debrief → surface follow-ups) is the same everywhere.

---

## Docs

Interactive docs page: [`chanakya/docs.html`](chanakya/docs.html) — or run `/chanakya-help` from inside Claude Code to open it.

Long-form manager walkthrough with 7 examples: [`chanakya/README.md`](chanakya/README.md).

---

## License

MIT
