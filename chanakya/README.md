# Chanakya + Achilles + Argus

A three-agent system for managing iOS development. Chanakya plans the work; Achilles executes it in an isolated git worktree, self-reviews, gates on a green build, invokes Argus for a cross-file pre-merge review, and merges back without ever touching your uncommitted changes.

All per-project artifacts live under `~/.dev-studio/<project>/` (outside `~/.claude/` so the agents don't trip the self-mod permission guard).

---

## Quick Reference

| Command | What it does |
|---------|-------------|
| `/chanakya` | Start planning — describe your tasks, get them organized |
| `/chanakya status` | See all tasks, their status, debt gauges, and what's next |
| `/chanakya brief T001` | Generate a self-contained brief for a task |
| `/chanakya brief-all` | Brief every `pending` task in priority order |
| `/chanakya ship T001,T002` | Brief + dispatch to Achilles in one step. Also `ship next`, `ship all` |
| `/chanakya sweep-debt` | Identify and dispatch all pending test sub-tasks and build checks |
| `/chanakya verify` | Guided flow: test-flow → you test → promote → review-feedback |
| `/chanakya reopen T347 --reason="<text>"` | Reopen a closed task (`verified`/`merged`/`archived`/`cancelled`) with a recorded reason and prior-debrief lineage. Re-brief next via `/chanakya brief T347` — the new brief inherits the round-2 context. Conventional reason prefixes: `qa-rejected:`, `design-rejected:`, `product-rejected:`, `regression:`, `incomplete:` |
| `/chanakya review` | Diff updated PRD against existing tasks |
| `/chanakya sweep` | Run Step 0 inbox sweep only — no status table (lighter for smoke-tests / pre-dispatch warm-ups) |
| `/chanakya update` | Sync master plan with git state |
| `/chanakya test-manifest` | Per-task verification checklist → `user-testing.md` |
| `/chanakya test-flow` | Journey-ordered single-sitting walkthrough → numbered round files |
| `/chanakya review-feedback` | Promote passing tasks to `verified`; file follow-ups for failures |
| `/chanakya compact` | Archive verified tasks, slim plan to actionable items only |
| `/chanakya sync-slack` | Sync Slack bug list statuses and Dev Notes with master plan |
| `/chanakya sync-slack --configure-token` | One-time: save Slack bot token to `~/.claude/secrets/` |
| `/chanakya sync-slack --configure` | One-time: configure project Slack list IDs in project memory |
| `/achilles T001` | Execute a briefed task. XS/S → LSP-only gate; M/L → full xcodebuild. Merges immediately on green. |
| `/achilles T001 --wait` | Same pipeline but pauses up to 10 min for test feedback before merging |
| `/achilles T001 --force-build` | Force full `xcodebuild` even for XS/S tasks |
| `/achilles T001 --ignore-build-debt` | Override build-debt block (discouraged; logged in debrief) |
| `/achilles T001 --dry-run` | Simulate every write + event; reads + LSP run normally. Exit 0 if wet-run would succeed, 2 if surfaced a problem. Phase 2.5 pilot. |
| `/achilles next` | Auto-pick the highest-priority ready task and execute it |
| `/achilles` | Direct mode — free-form task, no brief required |
| `/achilles build` | On-demand build check at HEAD. Green resets debt; red auto-bisects and files a P0 fix. |
| `/achilles debrief` | Direct-debrief: capture an in-chat bug-fix or quick-change into a YAML debrief (scans transcript + `git diff HEAD`, asks inline about tests). No brief, no worktree, no Argus, no git action. |

---

## Minimal Intervention

Chanakya runs end-to-end by default. You won't be asked "proceed?" at every step. The only points where it pauses for confirmation are:

| Pause point | Why |
|---|---|
| **Slack publish** (Step 6 of sync-slack) | Irreversible external write — you review the computed changes first |
| **First-time config writes** (`--configure-token`, `--configure`) | Writing a secret to disk; prompted once per setup |
| **Merge conflicts** | Achilles cannot resolve them automatically |
| **`--wait` mode feedback window** | You explicitly opted in to review before merge |

Everything else — inbox sweeps, debrief processing, brief generation, follow-up task creation, build debt updates — happens automatically. Run `/chanakya --away` before leaving the laptop to activate auto-sweep and push channels. Run `/chanakya --at-laptop` when you return to disable them. Use `--watch` or `--ship-mode` for fully hands-off sessions.

### Session flags

| Flag | Behavior |
|---|---|
| `--at-laptop` | Switch to at-laptop mode: disable auto-sweep, disable push channels. Default on fresh start. |
| `--away` | Switch to away mode: activate auto-sweep with adaptive backoff, enable push channels. |
| `--auto-sweep` | Background inbox sweep with adaptive backoff (15→30→60→120 min on blank sweeps; resets on activity). |
| `--watch` | `--auto-sweep` + auto-dispatch ready tasks after each sweep |
| `--ship-mode` | `--auto-sweep` + auto-dispatch + auto-verify when task queue drains |

---

## How It Works

```
You describe work
        |
        v
   /chanakya                         (organizes into tasks, assigns priorities)
        |
        v
   /chanakya brief T001              (fetches Figma, scans code, writes self-contained brief)
        |
        v
   /achilles T001                    (branches from committed HEAD into
                                      ~/.dev-studio/<project>/worktrees/T001/)
        |
        v
   implement → self-review (simplify) → green-build gate (serialized xcodebuild)
        |
        v
   write test cases → [optional --wait, auto-merge after 600s]
        |
        v
   /argus <task-id>  ←── auto-invoked by Achilles before merge ──→  approved/flagged/blocked
        |                                                                    |
        v (approved or flagged)                                    (blocked) → fix & retry
   merge --no-ff (serialized) → emit brief_completed event
        |
        v
   worktree + per-task DerivedData cleaned up; debrief dropped to inbox
        |
        v
   Chanakya sweeps inbox + event log — marks done, auto-files follow-ups from flagged reviews
        |
        v
   /chanakya test-manifest → you tick boxes → /chanakya review-feedback → verified
```

Default behavior is **merge immediately** and log a "manual verification" follow-up. Batch-test whenever with `/chanakya test-manifest` or `/chanakya test-flow`. Achilles never self-selects the next task — the user (or Chanakya) always drives.

### Safety guarantees

- Uncommitted changes in the main checkout are **never** touched — Achilles branches from committed HEAD.
- A red `xcodebuild` **never** merges. Branch + per-task DerivedData stay alive for inspection.
- **Argus blocks what must not ship.** Compile failures, test failures, secrets in diff, and base-branch staleness are hard blocks. Everything else flags and merges — with findings auto-filed as follow-up tasks by Chanakya.
- Merge conflicts are **never** force-resolved — Achilles surfaces them and stops.
- Builds and merges are **serialized across parallel Achilles instances** via `mkdir` locks in `~/.dev-studio/<project>/locks/` — designed for 6–10 parallel workers.
- **Test slots are shared fairly.** Argus uses a 3-slot file semaphore for concurrent test runs. XS/S reviews never run tests and never acquire a slot.
- `--wait` never hangs: a `ScheduleWakeup(600s)` auto-merges even if you're idle.
- **Build debt is tracked, not hidden.** Every XS/S task that skips `xcodebuild` increments a counter. Warn@6, block@12. `/achilles build` runs a full check on demand — green resets, red auto-bisects and files a P0 fix.
- **Event log is append-only.** All agents emit structured events. Chanakya processes them on each sweep — no polling, no 15-min wakes needed for follow-up surfacing.

Both agents are **proactive** — they always suggest the next step. You just say "yes", "no", or redirect.

---

## Argus — The Pre-Merge Reviewer

Argus runs automatically between Achilles's self-review and the merge step. You don't invoke it manually in normal flow — but you can run it standalone on any worktree:

```
/argus                   # review current worktree
/argus T001              # review a specific task's worktree
```

### What Argus checks (v1)

| Check | What it does | Week 1 verdict |
|---|---|---|
| Cross-file regression risk | Call-graph scan: does the diff break callers outside the worktree? | flag |
| Edge-case coverage | Enumerates negative inputs, empty states, concurrency edges; checks test coverage | flag |
| Test adequacy | Tests call changed functions but don't assert outcomes? | flag |
| Diff anomalies | Debug prints, commented-out code blocks, magic values, scope creep | flag |
| Base-branch staleness | Base advanced since the branch was created → must rebase | **block** |
| Secrets in diff | Credentials, API keys, tokens in diff's added lines | **block** |

**Week 1 posture:** only staleness and secrets are hard blocks. Everything else flags — merge proceeds and findings become Chanakya follow-up tasks automatically.

### Verdicts

- **Approved** — silent. Merge proceeds.
- **Flagged** — findings written to `<project-memory>/reviews/review_<task-id>.md`. Chanakya reads the `review_flagged` event and auto-files follow-up tasks. Merge proceeds.
- **Blocked** — Achilles loops back to fix the issue (max 3 cycles). Hard blocks: compile/test failure (M/L), secrets, staleness. No user input required for staleness (rebase) or code-fixable blocks.

### Concurrent test runs

M/L tasks trigger a targeted `xcodebuild test` run. Argus uses a 3-slot file semaphore at `~/.claude/locks/test-slots/` — up to 3 Argus instances can run tests in parallel. XS/S reviews skip the test phase entirely (fast path, seconds not minutes).

DerivedData is reused from Achilles's build — no recompile. A staleness guard checks build product mtimes vs HEAD commit timestamp and forces a rebuild only when necessary.

---

## Event Log

All agents write structured events to a daily append-only JSONL file:

```
~/.dev-studio/<project>/events/<YYYY-MM-DD>.jsonl
```

Each line: `{"ts":"ISO8601","agent":"achilles|argus|chanakya","event":"<name>","task":"T001","data":{...}}`

Chanakya processes new events on every sweep using a byte-offset marker (`events_offset.md`). This replaces the old 15-min scheduled wake for follow-up surfacing — Chanakya catches `review_flagged` and `brief_completed` events in its next auto-sweep tick.

**Push queue** (`~/.claude/state/push-queue.jsonl`): agents append here for high-priority events (`review_blocked`, `merge_conflict`, `build_debt_blocked`). Chanakya surfaces these in `/chanakya status`.

---

## Cleanup

Artifact cleanup is agent-owned and policy-driven:

| Artifact | Who cleans it | When |
|---|---|---|
| `.argus-running` marker | Argus (trap) | On exit |
| Test slot file | Argus (trap) | On test phase exit |
| Approved xcresult bundle | Argus | Immediately after approve |
| Flagged xcresult bundle | Chanakya | On `review_approved` event |
| Blocked xcresult bundle | Chanakya compact | After 48h |
| Review file | Chanakya | On `task_verified` → archived |
| Achilles worktree + DerivedData | Achilles | After clean merge |
| Event logs | Chanakya compact | Gzip >7d, delete >30d |

Run `/chanakya compact` to sweep all artifacts. `--sweep-artifacts` is on by default. For nightly auto-compact, `/chanakya compact --auto-compact` prints the cron setup command.

---

## When to Use Chanakya vs. Going Direct

| Situation | Use |
|-----------|-----|
| New feature with Figma designs | `/chanakya` to plan, then `/achilles` to implement |
| Multi-file refactor | `/chanakya` to plan |
| Simple bug fix / crash / one-file tweak | `/achilles` directly |
| Running 6–10 tasks in parallel | `/achilles T00X` × N (default no-wait) |
| Want to watch one merge | `/achilles T001 --wait` |
| Batch-test completed work | `/chanakya test-manifest` → edit → `/chanakya review-feedback` |
| Single-sitting manual walkthrough | `/chanakya test-flow` |
| PRD changed mid-feature | `/chanakya review` |
| Ship everything hands-off | `/chanakya ship all` → run tabs → `/chanakya verify` |

**Rule of thumb:** If you'd spend more than 2 minutes explaining the task to a worker, use Chanakya to write a brief. Otherwise, go direct.

---

## Examples

### Example 1: Quick Bug Fix (Direct to Achilles)

A crash in the app. No planning needed.

```
You:     /achilles
You:     The app crashes when tapping "Compare" after selecting a sticker.
         Stack trace points to PhotoEditorContainerView.swift in the
         comparison mode toggle. Fix it.

Achilles: [reads files, finds the bug, fixes it]
          "Fixed. The compare button's hit area was under the sticker overlay.
           Added allowsHitTesting(false) to stickers during comparison mode.
           Commit: abc1234."

Achilles: [writes YAML debrief to plans/debriefs/<debrief-id>.yaml]
          "No briefed tasks in the master plan. Want me to look at something else?"
```

Total time: one session, no planning overhead.

---

### Example 2: Single Feature with Figma (Chanakya + Achilles)

You need to build a new onboarding flow. There's a Figma design.

**Session 1 — Planning with Chanakya:**

```
You:     /chanakya
You:     I need to build the new onboarding flow for the app. Figma is here:
         https://www.figma.com/design/<file>?node-id=1:42171

Chanakya: "Got it. One task:
           T001 — Onboarding flow (P0, L complexity)
           Skills: figma-to-swiftui, swiftui-pro
           
           This is a single task, no dependencies. Master plan written.
           Brief T001?"

You:     Yes

Chanakya: [fetches Figma context, scans related files, inlines design specs]
          "Brief ready at chanakya-tasks/T001-onboarding-flow.md.
           It includes: screen states from Figma, design tokens, files to
           modify, patterns to follow, acceptance criteria.
           
           Ready to launch a worker?"
```

**Session 2 — Implementation with Achilles:**

```
You:     /achilles T001

Achilles: [reads brief — has everything: Figma specs, file paths, patterns]
          [marks T001 as in-progress in master plan]
          [implements the onboarding flow]
          
          "Done. Here's what I did:
           - OnboardingContainerView with 3-step flow
           - Page control, skip button, "Get Started" CTA
           - 3 commits: abc1234, def5678, ghi9012"

You:     Looks good.

Achilles: [writes YAML debrief to plans/debriefs/<debrief-id>.yaml]
          [links the debrief from the task artifact]
```

---

### Example 3: Multi-Task Feature with Dependencies (Full Workflow)

You're building a photo export feature. It has multiple tasks, some dependent on others, and the PRD changes halfway through.

**Session 1 — Planning:**

```
You:     /chanakya
You:     New feature: photo export. Here's what's needed:
         - Export settings panel (resolution, format, quality slider)
         - HEIF/JPEG/PNG format selection with preview
         - Share sheet integration
         - Export progress indicator
         Figma: https://www.figma.com/design/<file>?node-id=1:50000

Chanakya: "Organized into 4 tasks:
          
           T001 — Export settings panel (P0, L)
                  Skills: figma-to-swiftui, swiftui-pro
                  Dependencies: none
           
           T002 — Format selection with preview (P0, M)
                  Dependencies: T001
           
           T003 — Share sheet integration (P1, S)
                  Dependencies: T001
           
           T004 — Export progress indicator (P1, S)
                  Dependencies: T001
           
           T001 is the foundation — everything else depends on it.
           Brief T001?"

You:     Yes, and also assign swiftui-liquid-glass to T001.

Chanakya: [updates T001 skills, fetches Figma, scans codebase, writes brief]
          "T001 briefed. T002, T003, T004 can be briefed and run in
           parallel after T001 completes. Start a worker on T001?"
```

**Mid-feature PRD change:**

```
You:     /chanakya review
You:     Product updated the PRD: export now supports HEIF with alpha channel,
         and there's a new requirement for export history (last 10 exports).

Chanakya: [sweeps inbox — finds T001 debrief, processes it]
          "Processed T001 debrief. PRD Delta:
           - T002 (format selection) — affected: HEIF needs alpha channel. Updated.
           - NEW: T005 — Export history (last 10 exports). P2, M complexity.
           
           T003 and T004 are unaffected.
           Update the master plan?"

You:     Yes.
```

---

### Example 4: Parallel Workers in Separate Sessions

You have 3 briefed tasks that are independent. Run them in parallel using separate terminal tabs.

```
Terminal Tab 1:     /achilles T002
Terminal Tab 2:     /achilles T003
Terminal Tab 3:     /achilles T004
```

Each Achilles instance runs in its own worktree, acquires the build lock in turn, and drops a debrief. When you come back:

```
You:     /chanakya status

Chanakya: [sweeps inbox — finds 3 debriefs]
          "Processed 3 debriefs: T002, T003, T004 all done.
           T005 is now unblocked. Brief it?"
```

---

### Example 5: Picking Up Where You Left Off

You closed everything yesterday. Today you open a fresh session.

```
You:     /chanakya status

Chanakya: [reads master plan, sweeps inbox]
          "Master plan status:
           | ID   | Title              | Priority | Status      |
           |------|--------------------|----------|-------------|
           | T001 | Settings panel     | P0       | done        |
           | T002 | Format selection   | P0       | in-progress |
           | T003 | Share sheet        | P1       | briefed     |
           | T004 | Progress indicator | P1       | briefed     |
           
           T002 is marked in-progress but has no recent commits (stale 18h).
           Did the worker finish? If so, I can process it.
           
           T003 and T004 are ready for workers."

You:     T002 is done, the worker just didn't write a debrief. Mark it done.

Chanakya: [updates T002 to done]
          "Done. T003 and T004 are ready. Want me to brief T005 while
          you start a worker on T003?"
```

---

### Example 6: Ad-Hoc Bug Fix That Feeds Back to the Plan

Mid-feature, you spot a crash unrelated to the current work.

```
You:     /achilles
You:     There's a crash in the editor when rotating a text block
         past 360 degrees. The angle calculation overflows. Fix it.

Achilles: [finds the file, reads the rotation code, fixes the overflow]
          "Fixed. Wrapped angle with .truncatingRemainder(dividingBy: 360).
           Commit: xyz7890."

Achilles: [writes direct-mode YAML debrief to plans/debriefs/<debrief-id>.yaml]
```

Next time Chanakya runs, it picks up the direct debrief and ingests the structured artifact.

---

### Example 7: Full PRD + Figma — Large Feature from Scratch

You have a multi-page PRD from the product team, a Figma file with multiple screens, and need to plan the entire feature end-to-end.

**Session 1 — Feeding the PRD to Chanakya:**

```
You:     /chanakya
You:     New feature: Templates V2. Here's everything:

         PRD: ~/Downloads/Templates-V2-Spec.md
         
         Figma file: https://www.figma.com/design/<file>
         Key screens:
         - Template browser:     node-id=1:60100
         - Template preview:     node-id=1:60250
         - Category filter:      node-id=1:60400
         - Template customizer:  node-id=1:60550
         - Save/share flow:      node-id=1:60700
         
         Product context: This replaces the old template picker entirely.
         The old flow is in TemplateBrowserView.swift. Backend team is
         shipping new endpoints next week.

Chanakya: [reads the PRD file — extracts requirements, acceptance criteria,
           edge cases, technical requirements]
          [fetches all 5 Figma screens]
          [scans the existing codebase]
          
          "Read the PRD (42 requirements) and fetched all 5 Figma screens.
           Here's my breakdown:

           PHASE 1 — Foundation (no BE dependency)
           T001 — Category filter UI (P0, L)
           T002 — Template browser grid (P0, XL) — depends T001
           T003 — Template preview sheet (P0, M) — depends T002

           PHASE 2 — Requires BE endpoints
           T004 — API layer (P0, M) — can stub until BE ships
           T005 — Template customizer (P1, XL) — depends T003, T004
           T006 — Save/share flow (P1, M) — depends T005

           PHASE 3 — Polish
           T007 — Old template picker removal (P2, S) — after T001–T006
           T008 — Analytics events (P2, S) — after T001–T006

           3 requirements flagged as ambiguous — need product clarification:
             - 'Smart sort' — algorithm not specified
             - 'Custom color picker' — build or use system?
             - 'Share to Stories' — which platforms?

           Start briefing T001?"

You:     For the color picker, use the system color picker. Start briefing
         T001 and T004 in parallel.
```

**Chanakya briefing T001 (from PRD + Figma combined):**

```
Chanakya: "T001 brief generated. Contents:

          FROM PRD: 6 category types, horizontal scroll, 'All' default
          selected, count badges, accessibility labels.

          FROM FIGMA (node 1:60400): pill-shaped chips, 36pt height,
          selected state: filled brand color, glass material unselected,
          count badge top-right offset. Screenshot inlined.

          FROM CODEBASE: replaces header section in TemplateBrowserView.swift,
          existing CategoryModel is reusable, similar pattern in
          ModuleTabBar.swift.

          ACCEPTANCE CRITERIA (merged PRD + Figma):
          1. Horizontal scrollable chip bar with all PRD categories
          2. Visual match with Figma screenshot
          3. Glass material on unselected chips
          4. Selecting a category filters the grid below
          5. 'All' selected by default
          6. Count badges show per-category count
          7. VoiceOver announces '<Category> — <count> templates'

          T004 brief also ready. Launch workers?"
```

**The cycle continues** — each brief combines PRD requirements (the "what" and "why"), Figma specs (the "how it looks"), and codebase context (the "where and how to build it"). Workers get everything they need in one file.

---

**Key points for PRD-heavy workflows:**

1. **Give Chanakya the PRD file path** — it reads the whole document and extracts requirements per task.

2. **Give all Figma nodes upfront** — Chanakya maps them to tasks and fetches each during brief generation.

3. **Chanakya catches PRD gaps** — ambiguous requirements, missing specs, undefined algorithms. It flags them before workers hit them.

4. **PRD section references travel into briefs** — workers can trace requirements back to the spec.

5. **Phasing by dependency** — Chanakya identifies which tasks need backend endpoints and which can start immediately with mocks.

---

## Composite Commands

One command, minimal manual involvement:

| Command | What it chains |
|---|---|
| `/chanakya brief-all` | Brief every `pending` task in priority order |
| `/chanakya ship T001,T002` | `brief` + generate dispatch plan for Achilles |
| `/chanakya ship next` | Brief + dispatch the next highest-priority unblocked task |
| `/chanakya ship all` | Brief + dispatch all unblocked tasks |
| `/chanakya sweep-debt` | Identify + brief all pending test sub-tasks and build checks |
| `/chanakya verify` | `test-flow` → you test → `promote` → `review-feedback` |
| `/chanakya compact` | Archive verified tasks, regenerate Dashboard/Module Index, trim to ~500 lines |
| `/achilles next` | Pick highest-priority briefed task and execute it |
| `/achilles next 3` | Generate a parallel dispatch plan for 3 tasks |
| `/achilles group T001` | Execute implementation + unit tests + UI tests sequentially |
| `/achilles test-suite unit` | Run full unit test suite. Also `ui`, `all`. |

**Typical hands-off sequences:**

| Goal | Commands | User actions |
|---|---|---|
| Ship a feature end-to-end | `/chanakya ship all` → run tabs → `/chanakya verify` | 3 |
| Clear all debt | `/chanakya sweep-debt` → run tabs | 2 |
| Implement + test one task | `/achilles group T001` | 1 |
| Full regression suite | `/achilles test-suite all` | 1 |
| Brief everything, then ship | `/chanakya brief-all` → `/chanakya ship all` | 2 |

---

## Sync-Slack

Keeps a Slack Lists bug tracker synchronized with the Chanakya master plan. Reads task statuses, writes Status + Dev Notes + Fixed in Build back to Slack. Designed to run automatically after every TestFlight build.

**One-time setup:**

```
/chanakya sync-slack --configure-token   # paste your Slack bot token (xoxb-...)
/chanakya sync-slack --configure         # enter list ID, column IDs, status option IDs
```

**Manual sync:**

```
/chanakya sync-slack                     # sync against latest build
/chanakya sync-slack --build 3137        # sync for a specific build number
/chanakya sync-slack --list <LIST_ID>    # override default list
```

**Auto-triggered:** When Chanakya processes a TestFlight release debrief, it automatically computes the Slack sync and presents the table for confirmation before writing.

Token is stored at `~/.claude/secrets/slack-bot-token` (chmod 600), cross-project. Project config (list ID, column IDs, stakeholder handles) lives in `project_slack_list_sync.md` in project memory.

---

## File System

After a typical feature lifecycle, here's what the file tree looks like:

```
~/.dev-studio/<project>/                      # slug = basename of git toplevel
  plans/
    chanakya-master.md                        # The master plan
    user-testing.md                           # Consolidated manual-test file (on demand)
    user-testing-archive/                     # Past manifests after review-feedback
    chanakya-tasks/
      T001-onboarding-flow.md                 # Brief (written by Chanakya)
      T001-tests.md                           # Test cases (written by Achilles)
      T002-format-selection.md
      ...
    debriefs/
      0190f52a-...yaml                        # Structured Achilles debriefs
      0190f52b-...yaml
  worktrees/                                  # Per-task isolated checkouts
    T001/                                     # branch achilles/T001 — removed on clean merge
    build-20260415-143200/                    # /achilles build — detached HEAD, retained on red
  locks/                                      # mkdir locks — serialize xcodebuild & merges
    xcodebuild.lock/
    git-merge.lock/

/tmp/
  derived-data/                               # Per-task xcodebuild output (NOT in ~/.dev-studio)
    T001/                                     # cleaned on clean merge, retained on failure
    build-20260415-143200/                    # /achilles build — retained on red
  argus-T001.xcresult                         # Argus test result bundle (deleted on approve)

~/.claude/projects/-Users-.../memory/
  events/
    2026-04-18.jsonl                          # Append-only event log
    2026-04-17.jsonl.gz                       # Rotated (>7 days → gzip, >30 days → delete)
  events_offset.md                            # Chanakya's byte offset into today's event log
  reviews/
    review_T001.md                            # Argus review file (archived on task_verified)
    archive/
      review_T001.md                          # Archived (deleted >30 days)

~/.claude/locks/test-slots/                   # Argus 3-slot semaphore
~/.claude/state/push-queue.jsonl              # Push notification queue
```

---

## Tips

1. **Start small.** Try `/achilles` on a bug fix first. Then try `/chanakya` on a small feature. Scale up as you get comfortable.

2. **Chanakya always suggests next steps.** Just say "yes" to keep moving. Say "do T003 instead" to redirect. Say "I'm done for now" to stop.

3. **Default is no-wait.** Plain `/achilles T001` merges as soon as the build goes green and logs a manual-verification follow-up. Add `--wait` only when you want to test before the merge.

4. **Achilles never self-picks.** Control returns to you (or Chanakya) after every completion. Follow-ups are surfaced by Chanakya's event-log sweep — no fixed 15-min delay.

5. **Briefs are snapshots.** If the codebase changes significantly between briefing and execution, Achilles may flag stale references. Just regenerate with `/chanakya brief T001`.

6. **Debriefs are where knowledge lives.** The Key Learnings section in debriefs feeds into project memory. Be generous with feedback — tell Achilles what was tricky, what was surprising, what future sessions should know.

7. **Go parallel aggressively.** Fire 6–10 `/achilles T00X` in separate tabs. Each runs in its own worktree with its own DerivedData; builds and merges serialize automatically via `~/.dev-studio/<project>/locks/`.

8. **PRD changes mid-flight are normal.** Use `/chanakya review` to diff the changes against existing tasks. Chanakya tells you exactly what's affected and what needs re-briefing.

9. **Batch-test on your schedule.** Run `/chanakya test-manifest` when you're ready. Tick boxes in `user-testing.md`, note failures, then `/chanakya review-feedback` promotes passes to `verified` and files follow-ups for failures.

10. **Red builds don't merge.** If the build gate fails, Achilles stops. Inspect under `~/.dev-studio/<project>/worktrees/<id>/` — the branch and DerivedData are preserved.

11. **Run `/achilles build` when you feel like it.** No task ID needed — it builds HEAD in a detached worktree, auto-bisects on red, and Chanakya resets the debt counter on its next sweep. Fast-path no-op if HEAD is already the last known green.

12. **Escalation triggers protect you.** Even if a task is declared XS/S, Achilles forces a full build whenever the diff touches `import`, `public`, `protocol`, `actor`, `async`, generics, `Package.swift`, or any file-level rename/add/delete. The skip is only for the cases where it's obviously safe.

13. **Build debt banner is informational.** Warn@6 prints on every Chanakya invocation until you run `/achilles build`. Block@12 also refuses new briefs — override with `/achilles T0XX --ignore-build-debt` (recorded in the debrief).

14. **Not everything needs a plan.** A one-line crash fix doesn't need Chanakya. Just `/achilles` and describe the bug. The debrief still gets logged for tracking.
