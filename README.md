# Generic Dev Studio

A two-agent system for Claude Code. **Chanakya** plans the work; **Achilles** executes it in an isolated git worktree, self-reviews, gates on a green build, and hands off follow-ups without ever touching your uncommitted changes.

Built around an iOS/SwiftUI project (Turnip) but the orchestration layer is codebase-agnostic.

---

## TL;DR

```
/chanakya                 # describe features → get a master plan
/chanakya brief T001      # generate a self-contained worker brief for T001
/achilles T001            # execute the brief on an isolated worktree
/achilles                 # direct mode — free-form task, no brief required
/chanakya status          # see what's in flight
```

Achilles never self-selects the next task. Once a task is done and the debrief is handed off, it sits idle. The user (or Chanakya) drives the next move.

---

## What's in the Repo

```
chanakya/
  SKILL.md      # manager agent — intake, briefing, status, PRD review, inbox sweep
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

### One-time directories

```bash
mkdir -p ~/.claude/plans/chanakya-tasks
mkdir -p ~/.claude/plans/chanakya-inbox/processed
mkdir -p ~/.claude/worktrees/turnip-ios
```

### Permissions

Achilles and Chanakya need `Read`, `Write`, `Edit`, and `Bash(git *)` to run unattended (worktree creation, merges, inbox moves). These are typically already allowed in `~/.claude/settings.json`.

---

## How It Works

### Chanakya — the manager

1. **Intake** — you paste features, Figma links, PRD bullets, or crash logs. Chanakya turns them into tasks with IDs (`T001`, `T002`, …), priorities (P0/P1/P2), complexity, and skill assignments.
2. **Brief generation** — for plan-worthy tasks, Chanakya writes a **self-contained** brief that inlines Figma specs, codebase pointers, acceptance criteria, and architectural constraints. A worker reads *only* that brief — no extra spelunking.
3. **Inbox sweep** — every invocation (and optionally every 10 min in the background) processes debriefs from `chanakya-inbox/`: marks tasks done, records commit hashes, auto-creates and briefs any follow-up tasks, and stamps each follow-up with a `Source:` pointer to its parent.
4. **PRD delta** — `/chanakya review` diffs an updated PRD against the master plan and flags which tasks need rework.
5. **Retrospective** — when all tasks for a feature are done, Chanakya compiles a feature memory into `~/.claude/projects/.../memory/` so the knowledge survives across sessions.

### Achilles — the worker

Achilles runs a strict 10-step pipeline. The flow is the same whether the task comes from a Chanakya brief or from a direct-mode instruction:

```
1. Load spec                — read brief or ask the user
2. Claim the task           — set master plan status to in-progress
3. Isolate                  — git worktree add from committed HEAD
                              (uncommitted changes stay untouched)
4. Implement                — small logical commits against the brief
5. Self-review              — one iteration via the `simplify` skill
6. Green build gate         — xcodebuild must pass; no merge otherwise
7. Write test cases         — standalone artifact + prompt user;
                              ScheduleWakeup(600s) as timeout
8. Process feedback         — iterate, or time out gracefully
9. Commit + merge --no-ff   — merge into ORIG_BRANCH locally, then
   + worktree remove          delete the worktree
10. Debrief + short summary — drop debrief for Chanakya, tell the user
11. (+900s) surface follow-ups — on wake, scan master plan for every
                                 task whose Source: is this task, list
                                 them with acceptance criteria, then idle
```

Key guarantees:

- Your uncommitted working-tree changes in the main checkout are **never** disturbed — Achilles always branches from the committed HEAD into `~/.claude/worktrees/turnip-ios/<task-id>/`.
- A red build is **never** merged. The branch is left alive for inspection.
- Merge conflicts are **never** force-resolved. Achilles stops and surfaces them.
- Achilles never self-picks the next task. Control returns to the user after each completion.

---

## Examples

### Example 1 — Full feature loop

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

you: yes

chanakya: Brief saved to chanakya-tasks/T001-export-flow.md.
          Figma tokens inlined, 4 files identified, AC has 7 items.
          T002 is independent — brief it next, or kick off T001?

you: /achilles T001

achilles: Branching achilles/T001 from main@3c239a5.
          Worktree at ~/.claude/worktrees/turnip-ios/T001/.
          [implements through AC, runs simplify pass, builds green]

          T001 implementation is done and the build is green.
          Test cases are at chanakya-inbox/T001-tests.md.
          Please run through them and share any feedback — I'll wait
          up to 10 minutes.

you: [runs the test plan] looks good, HEIF toggle works, ship it

achilles: Merged achilles/T001 into main (local, --no-ff, commit b41f2aa).
          Worktree removed. Debrief dropped for Chanakya.

          **T001 done.** Branched from main@3c239a5, implemented,
          self-reviewed, build green, merged back. Test cases at
          T001-tests.md. Debrief dropped for Chanakya.

          [15 min later, on wake]

          **Follow-ups from T001 are ready.** Chanakya created T014.
          - T014 — Verify HEIF export in low-storage scenario:
            [criteria]
```

### Example 2 — Direct-mode bug fix

```
you: /achilles
you: The CollageGridView crashes when the user opens an empty album.
     Stack trace: ... Array index out of range at line 142.

achilles: Reproduced from the trace. Guard against empty sections
          before the stride call.
          [patches, self-reviews, builds green, writes test cases]

          Done. 1 commit, 1 file changed. Test cases at
          direct-a1b2c3d-tests.md.
```

### Example 3 — User doesn't respond to test request

```
achilles: Please run through [test cases] — I'll wait up to 10 minutes.
          [no reply; 600s wake fires]

achilles: 10 min elapsed. Logged a manual-verification follow-up in the
          debrief. Merging and cleaning up.
          **T007 done.** …
```

### Example 4 — Red build blocks merge

```
achilles: [Step 6] xcodebuild failed — missing symbol `ExportHEIFOptions`.
          Fix attempt 1: added import → still fails, SPM package not listed.
          Surfacing: this looks like a missing dependency. Not merging.
          Branch achilles/T009 is left in place for you to inspect at
          ~/.claude/worktrees/turnip-ios/T009/.
```

### Example 5 — Background sweep

```
you: /chanakya
chanakya: Enable background inbox sweep every 10 min for this session?
          (y/n)
you: y
chanakya: Will sweep every 600s. [sweep runs silently unless
          something was processed]

          [10 min later, silent tick — inbox empty]
          [20 min later]
chanakya: Processed T005 — done, 1 follow-up briefed (T018).
```

---

## When to Use What

| Situation                          | Tool                                  |
|------------------------------------|---------------------------------------|
| New feature with Figma             | `/chanakya` → `/achilles`             |
| Multi-file refactor                | `/chanakya` → `/achilles`             |
| Bug fix / crash                    | `/achilles` (direct mode)             |
| One-file UI tweak                  | `/achilles` (direct mode)             |
| PRD changed mid-feature            | `/chanakya review`                    |
| Check what's in flight             | `/chanakya status`                    |
| Nudge Chanakya to re-scan inbox    | `/chanakya` (Step 0 runs on entry)    |

---

## Adapting to Other Projects

The core orchestration is project-agnostic. To port:

1. **Swap the skill registry** in `chanakya/SKILL.md` — replace the Swift/SwiftUI skill table with your stack's equivalents.
2. **Swap the build command** in `achilles/SKILL.md` Step 6 — replace `xcodebuild` with `cargo build`, `pnpm build`, `go build`, whatever applies.
3. **Swap the worktree root** — default is `~/.claude/worktrees/turnip-ios/`; pick a name per repo.
4. **Drop Figma if unused** — remove the MCP calls from Brief Generation Step 3.
5. **Update project memory path** in both SKILL.md files.

The pipeline (isolate → implement → self-review → green build → user feedback → merge-back → debrief → surface follow-ups) is the same everywhere.

---

## Docs

Interactive docs page: [`chanakya/docs.html`](chanakya/docs.html) — or run `/chanakya-help` from inside Claude Code to open it.

Long-form manager walkthrough with 7 examples: [`chanakya/README.md`](chanakya/README.md).

---

## License

MIT
