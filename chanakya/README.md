# Chanakya + Achilles

A two-agent system for managing iOS development. Chanakya plans the work, Achilles executes it.

---

## Quick Reference

| Command | What it does |
|---------|-------------|
| `/chanakya` | Start planning — describe your tasks, get them organized |
| `/chanakya status` | See all tasks, their status, and what's next |
| `/chanakya brief T001` | Generate a self-contained brief for a task |
| `/chanakya review` | Diff updated PRD against existing tasks |
| `/chanakya update` | Sync master plan with git state |
| `/achilles T001` | Pick up a briefed task and implement it |
| `/achilles` | Direct mode — describe a task, Achilles does it |

---

## How It Works

```
You describe work
        |
        v
   /chanakya
   (organizes into tasks, assigns priorities)
        |
        v
   /chanakya brief T001
   (fetches Figma, scans code, writes self-contained brief)
        |
        v
   /achilles T001          (new session or same session)
   (reads brief, implements, asks for feedback)
        |
        v
   Achilles writes debrief to inbox
        |
        v
   /chanakya status        (auto-processes inbox)
   (updates master plan, suggests next task)
```

Both agents are **proactive** — they always suggest the next step. You just say "yes", "no", or redirect.

---

## When to Use Chanakya vs. Going Direct

| Situation | Use |
|-----------|-----|
| New feature with Figma designs | `/chanakya` to plan, then `/achilles` to implement |
| Multi-file refactor | `/chanakya` to plan |
| Simple bug fix | `/achilles` directly |
| One-file UI tweak | `/achilles` directly |
| Crash fix | `/achilles` directly |
| PRD changed mid-feature | `/chanakya review` |

**Rule of thumb:** If you'd spend more than 2 minutes explaining the task to a worker, use Chanakya to write a brief. Otherwise, go direct.

---

## Examples

### Example 1: Quick Bug Fix (Direct to Achilles)

A crash in the photo editor. No planning needed.

```
You:     /achilles
You:     The app crashes when tapping "Compare" after selecting a sticker.
         The crash is in PhotoEditorContainerView.swift somewhere in the
         comparison mode toggle. Fix it.

Achilles: [reads files, finds the bug, fixes it]
          "Fixed. The compare button's hit area was under the sticker overlay.
           Added allowsHitTesting(false) to stickers during comparison mode.
           Commit: abc1234. Any feedback?"

You:     Looks good.

Achilles: [writes debrief to inbox]
          "No briefed tasks in the master plan. Want me to look at something else?"
```

Total time: one session, no planning overhead.

---

### Example 2: Single Feature with Figma (Chanakya + Achilles)

You need to build a new FAB (floating action button) for the home screen. There's a Figma design.

**Session 1 — Planning with Chanakya:**

```
You:     /chanakya
You:     I need to build the new FAB for the home screen. Figma is here:
         https://www.figma.com/design/DMRP0bv9T9oUbGCC5esB01/Zaps-iOS?node-id=1:42171

Chanakya: "Got it. One task:
           T001 — Home screen FAB redesign (P1, M complexity)
           Skills: figma-to-swiftui, swiftui-pro
           
           This is a single task, no dependencies. Master plan written.
           Shall I generate the brief for T001?"

You:     Yes

Chanakya: [fetches Figma context, scans HomeView.swift and related files,
           inlines design specs into brief]
          "Brief ready at chanakya-tasks/T001-fab-redesign.md.
           It includes: collapsed/expanded states from Figma, screenshot,
           design tokens, files to modify (HomeView.swift, CreateNewFABView.swift),
           patterns to follow, acceptance criteria.
           
           Ready to launch a worker?"
```

**Session 2 — Implementation with Achilles:**

```
You:     /achilles T001

Achilles: [reads brief — has everything: Figma specs, file paths, patterns]
          [marks T001 as in-progress in master plan]
          [invokes /figma-to-swiftui and /swiftui-pro for guidance]
          [implements the FAB]
          
          "Done. Here's what I did:
           - Replaced CreateNewFABView with new collapsed/expanded design
           - Added expansion animation with spring timing
           - Template grid navigates to creation flows
           - 3 commits: abc1234, def5678, ghi9012
           
           Any feedback?"

You:     The expanded panel background should be more translucent.

Achilles: [adjusts opacity]
          "Updated. Material opacity changed from 0.7 to 0.5. Any other feedback?"

You:     Good, ship it.

Achilles: [writes debrief to chanakya-inbox/T001-debrief.md]
          [marks T001 as done in master plan]
          "All tasks complete. No more briefed tasks in the master plan."
```

---

### Example 3: Multi-Task Feature with Dependencies (Full Workflow)

You're building the photo editor export feature. It has multiple tasks, some dependent on others, and the PRD changes halfway through.

**Session 1 — Planning:**

```
You:     /chanakya
You:     New feature: photo editor export. Here's what's needed:
         - Export settings panel (resolution, format, quality slider)
         - HEIF/JPEG/PNG format selection with preview
         - Share sheet integration
         - Export progress indicator
         - Watermark overlay (optional, toggle in settings)
         Figma: https://www.figma.com/design/DMRP0bv9T9oUbGCC5esB01/Zaps-iOS?node-id=1:50000

Chanakya: "Organized into 5 tasks:
          
           T001 — Export settings panel (P0, L)
                  Skills: figma-to-swiftui, swiftui-pro
                  Dependencies: none
           
           T002 — Format selection with preview (P0, M)
                  Skills: figma-to-swiftui, swiftui-pro
                  Dependencies: T001 (needs settings panel structure)
           
           T003 — Share sheet integration (P1, S)
                  Skills: swiftui-pro
                  Dependencies: T001
           
           T004 — Export progress indicator (P1, S)
                  Skills: figma-to-swiftui, swiftui-pro
                  Dependencies: T001
           
           T005 — Watermark overlay (P2, M)
                  Skills: imgly-engine-expert, swiftui-pro
                  Dependencies: T001
           
           Parallelization:
           T001 ──┬── T002 (sequential)
                  ├── T003 (parallel after T001)
                  ├── T004 (parallel after T001)
                  └── T005 (parallel after T001)
           
           T001 is the foundation — everything else depends on it.
           Shall I brief T001?"

You:     Yes, and also assign swiftui-liquid-glass to T001, the panel
         should use glass effects.

Chanakya: [updates T001 skills, fetches Figma, scans codebase, writes brief]
          "T001 briefed. It includes: settings panel Figma specs (3 nodes),
           glass effect guidance, file paths, acceptance criteria.
           
           T002 can't be briefed yet (depends on T001). Brief T003, T004,
           or T005 in parallel? They're independent of each other."

You:     Brief T003 and T004.

Chanakya: [generates both briefs]
          "T003 and T004 briefed. Ready to launch workers.
           Suggested plan:
           - Start T001 now (foundation, P0)
           - After T001 is done, start T002, T003, T004 in parallel
           - T005 (watermark) is P2, brief it later"
```

**Session 2 — Worker on T001:**

```
You:     /achilles T001

Achilles: [reads brief, claims task, implements export settings panel]
          "Done. Export settings panel with glass effect, resolution picker,
           format selector stub, quality slider. 4 commits.
           
           Key finding: the existing PhotoEditorNavBar uses a different
           glass material than what Figma specifies — I matched Figma
           but you may want to unify later.
           
           Any feedback?"

You:     Looks great.

Achilles: [writes debrief with the glass material observation in Key Learnings]
          "T003 (share sheet) and T004 (progress indicator) are both briefed
           and unblocked now. Want me to pick up T003?"

You:     Yes.

Achilles: [reads T003 brief, implements share sheet integration]
          ...continues working...
```

**Session 1 — Mid-feature PRD change:**

```
You:     /chanakya review
You:     Product team updated the PRD. Changes:
         - Export now supports HEIF with alpha channel
         - Watermark is no longer optional, it's always shown for free users
         - New requirement: export history (last 10 exports)

Chanakya: [auto-sweeps inbox first — finds T001 debrief]
          "Processed T001 debrief. Key learning: glass material inconsistency
           between NavBar and new panel. Noted for future reference.
           
           PRD Delta:
           - T002 (format selection) — PENDING, affected: HEIF now needs
             alpha channel support. Updated description.
           - T005 (watermark) — PENDING, changed: no longer optional,
             always shown for free users. Priority bumped to P1.
             Brief needs regeneration.
           - NEW: T006 — Export history (last 10 exports). P2, M complexity.
           
           T003 and T004 are unaffected.
           
           Update the master plan with these changes?"

You:     Yes.

Chanakya: [updates master plan]
          "Done. T002 is next for briefing (P0, unblocked now that T001 is done).
           Brief it?"
```

**After all tasks are done:**

```
You:     /chanakya status

Chanakya: [auto-sweeps inbox — processes remaining debriefs]

          "All 6 tasks complete:
           | ID   | Title              | Status | Commits     |
           |------|--------------------|--------|-------------|
           | T001 | Settings panel     | done   | abc1234...  |
           | T002 | Format selection   | done   | def5678...  |
           | T003 | Share sheet        | done   | ghi9012...  |
           | T004 | Progress indicator | done   | jkl3456...  |
           | T005 | Watermark          | done   | mno7890...  |
           | T006 | Export history     | done   | pqr1234...  |
           
           Compiling learnings into project memory..."
           
          [writes project_photo_editor_export.md to memory with:
           - Glass material inconsistency finding
           - HEIF alpha channel implementation pattern
           - Export pipeline architecture decisions]
          
          "Feature retrospective saved. Key learnings:
           - Glass materials need unification across editor (from T001)
           - HEIF with alpha requires CGImageDestination, not UIImage (from T002)
           - Export history uses SwiftData with 10-item ring buffer (from T006)
           
           These are now in project memory for future sessions."
```

---

### Example 4: Parallel Workers in Separate Sessions

You have 3 briefed tasks that are independent. Run them in parallel using separate terminal tabs or worktrees.

```
Terminal Tab 1:
You:     /achilles T002

Terminal Tab 2:
You:     /achilles T003

Terminal Tab 3:
You:     /achilles T004
```

Each Achilles instance:
- Reads its own brief (self-contained, no overlap)
- Marks its task as `in-progress` in the master plan
- Implements independently
- Writes its own debrief to the inbox
- Suggests the next task when done

When you come back to Chanakya:
```
You:     /chanakya status

Chanakya: [sweeps inbox — finds 3 debriefs]
          "Processed 3 debriefs: T002, T003, T004 all done.
           Key learnings compiled. T005 is now unblocked. Brief it?"
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
           | T005 | Watermark          | P1       | pending     |
           
           T002 is marked in-progress but has no recent commits (stale 18h).
           Did the worker finish? If so, I can process it.
           
           T003 and T004 are ready for workers."

You:     T002 is done, the worker just didn't write a debrief. Mark it done.

Chanakya: [updates T002 to done]
          "Done. T003 and T004 are ready. T005 needs a brief.
           Want me to brief T005 while you start a worker on T003?"
```

---

### Example 6: Ad-Hoc Bug Fix That Feeds Back to the Plan

Mid-feature, you spot a crash that's unrelated to the current work.

```
You:     /achilles
You:     There's a crash in CollageEditorView when rotating a text block
         past 360 degrees. The angle calculation overflows. Fix it.

Achilles: [finds the file, reads the rotation code, fixes the overflow]
          "Fixed. Wrapped angle calculation with .truncatingRemainder(dividingBy: 360).
           Commit: xyz7890.
           
           Any feedback?"

You:     Good.

Achilles: [writes debrief to chanakya-inbox/direct-xyz7890-debrief.md]
          "T003 (share sheet) is briefed and available. Want me to pick it up?"
```

Next time Chanakya runs, it picks up the ad-hoc debrief and logs it in the master plan — the crash fix is tracked even though it was never formally planned.

---

### Example 7: Full PRD + Figma — Large Feature from Scratch

You have a 20-page PRD from the product team, a Figma file with multiple screens, and you need to plan the entire feature end-to-end.

**Session 1 — Feeding the PRD to Chanakya:**

```
You:     /chanakya
You:     New feature: Collage Templates V2. Here's everything:

         PRD: ~/Downloads/Collage Templates V2 - Product Spec.md
         
         Figma file: https://www.figma.com/design/DMRP0bv9T9oUbGCC5esB01/Zaps-iOS
         Key screens:
         - Template browser:     node-id=1:60100
         - Template preview:     node-id=1:60250
         - Category filter:      node-id=1:60400
         - Template customizer:  node-id=1:60550
         - Save/share flow:      node-id=1:60700
         
         Product context: This replaces the old template picker entirely.
         The old flow is in TemplateBrowserView.swift. Backend team is
         shipping new endpoints next week (GET /v2/templates, 
         GET /v2/templates/:id/variants). Design team says the category
         filter is the highest priority screen — it's what users see first.

Chanakya: [reads the PRD file — extracts feature sections, acceptance
           criteria, edge cases, and technical requirements]
          [reads the Figma nodes — fetches design context for all 5 screens]
          [scans the existing codebase — finds TemplateBrowserView.swift,
           TemplateEditorView.swift, related view models and API layer]
          
          "I've read the PRD (47 requirements across 8 sections) and
           fetched all 5 Figma screens. Here's my breakdown:

           PHASE 1 — Foundation (no BE dependency)
           T001 — Category filter UI (P0, L)
                  PRD sections: 2.1, 2.2, 2.3
                  Figma: node 1:60400
                  Skills: figma-to-swiftui, swiftui-liquid-glass, swiftui-pro
                  Notes: Product says this is what users see first.
                  Replaces: TemplateBrowserView.swift header

           T002 — Template browser grid (P0, XL)
                  PRD sections: 3.1–3.6
                  Figma: node 1:60100
                  Skills: figma-to-swiftui, swiftui-pro, swiftui-performance-audit
                  Dependencies: T001 (filter feeds into grid)
                  Notes: PRD specifies infinite scroll with prefetch.
                  Performance-sensitive — grid can have 500+ items.

           T003 — Template preview sheet (P0, M)
                  PRD sections: 4.1–4.3
                  Figma: node 1:60250
                  Skills: figma-to-swiftui, swiftui-pro
                  Dependencies: T002 (tapping grid item opens preview)

           PHASE 2 — Requires BE endpoints
           T004 — API layer for /v2/templates (P0, M)
                  PRD section: 7.1 (API contract)
                  Skills: swift-concurrency-pro, swift-architecture-skill
                  Dependencies: none (can stub until BE ships)
                  Notes: PRD has the full request/response schema on page 12.
                  BE ships next week — build against mocks first.

           T005 — Template customizer (P1, XL)
                  PRD sections: 5.1–5.8
                  Figma: node 1:60550
                  Skills: figma-to-swiftui, imgly-engine-expert, swiftui-pro
                  Dependencies: T003, T004
                  Notes: This is the heaviest screen — uses IMGLY engine
                  for live template manipulation. PRD lists 12 customization
                  options (colors, text, images, layouts).

           T006 — Save/share flow (P1, M)
                  PRD sections: 6.1–6.4
                  Figma: node 1:60700
                  Skills: figma-to-swiftui, swiftui-pro
                  Dependencies: T005

           PHASE 3 — Polish
           T007 — Old template picker migration/removal (P2, S)
                  PRD section: 8.1 (deprecation plan)
                  Dependencies: T001–T006 all done
                  Notes: Remove TemplateBrowserView.swift, update
                  all navigation entry points.

           T008 — Analytics events (P2, S)
                  PRD section: 7.3 (event table)
                  Dependencies: T001–T006

           DIRECT (no brief needed):
           T009 — Update API mock fixtures for tests (P2, S)
           T010 — Add feature flag for gradual rollout (P1, S)

           Parallelization:
           T001 ──── T002 ──── T003 ──┐
           T004 (parallel) ───────────┤──── T005 ──── T006
                                      │
           T010 (parallel, direct) ────┘
                                      T007, T008 (after all above)

           10 tasks total: 8 plan-worthy, 2 direct.
           PRD coverage: all 47 requirements mapped to tasks.
           3 requirements flagged as ambiguous — need product clarification:
             - PRD 3.4: 'Smart sort' — algorithm not specified
             - PRD 5.6: 'Custom color picker' — build or use system?
             - PRD 6.2: 'Share to Stories' — which platforms?

           Shall I start briefing T001 (category filter)? It's the
           product team's top priority and has no dependencies."

You:     For PRD 5.6, use the system color picker. The other two I'll
         check with product. Start briefing T001, and also T004 since
         it can run in parallel.

Chanakya: [updates T005 notes: system color picker confirmed]
          [starts briefing T001 and T004 in parallel]
```

**Chanakya briefing T001 (from PRD + Figma combined):**

```
Chanakya: "T001 brief generated. Here's what's in it:

          FROM PRD:
          - 6 category types with icons (PRD 2.1)
          - Horizontal scroll with 'All' default selected (PRD 2.2)
          - Category count badges update in real-time (PRD 2.3)
          - Accessibility: VoiceOver labels for each category (PRD 2.3.1)

          FROM FIGMA (node 1:60400):
          - Pill-shaped category chips, 36pt height
          - Selected state: filled orange (#FF4C24), white text
          - Unselected: glass material background, gray text
          - Horizontal padding: 16pt between chips
          - Count badge: 12pt circle, top-right offset
          - Screenshot inlined in brief

          FROM CODEBASE:
          - Replaces header section in TemplateBrowserView.swift (lines 45-89)
          - Existing CategoryModel in Models/TemplateCategory.swift — reuse it
          - Similar pattern: PhotoEditorModuleTabBar.swift (horizontal chip scroll)
          - API mock: TemplateMockData.swift has category fixtures

          ACCEPTANCE CRITERIA (merged from PRD + Figma):
          1. Horizontal scrollable chip bar with all PRD categories
          2. Visual match with Figma screenshot
          3. Glass material on unselected chips (iOS 26+)
          4. Selecting a category filters the grid below (T002 integration point)
          5. 'All' selected by default on launch
          6. Count badges show per-category template count
          7. VoiceOver announces '<Category> — <count> templates'

          T004 brief also ready (API layer with full request/response
          schema from PRD page 12, mock-first approach).

          Next: T002 depends on T001. T003 depends on T002.
          Want to launch a worker for T001 while I wait to brief T002?"

You:     Yes, launch T001. Brief T010 (feature flag) too, that's quick.

Chanakya: "T010 is a direct task — no brief needed. Just tell Achilles:
           'Add a feature flag for CollageTemplatesV2, default off,
           using the existing FeatureFlags.swift pattern.'

           Ready when you want to start a worker on T001."
```

**Session 2 — Achilles working from the PRD-enriched brief:**

```
You:     /achilles T001

Achilles: [reads the brief — has PRD requirements, Figma specs, code paths,
           and acceptance criteria all in one place]
          [invokes /figma-to-swiftui for the category filter design]
          [invokes /swiftui-liquid-glass for glass chip styling]
          [finds and reuses CategoryModel from TemplateCategory.swift]
          [follows the PhotoEditorModuleTabBar pattern for chip scroll]
          
          "Done. Category filter bar implemented with:
           - 6 categories from PRD, horizontal scroll
           - Glass material chips matching Figma exactly
           - Count badges with real-time updates
           - VoiceOver labels per PRD 2.3.1
           - Reused existing CategoryModel (no new model needed)
           - 3 commits
           
           One thing: PRD says 'Smart sort' for categories but doesn't
           define the algorithm. I used alphabetical for now. Flag this
           for product?
           
           Any feedback?"

You:     Yes, flag it. The rest looks good.

Achilles: [writes debrief — includes the 'Smart sort' ambiguity in
           Follow-up Tasks and the CategoryModel reuse in Key Learnings]
          "T002 (template grid) depends on T001 and is next in priority.
           But it needs a brief first — ask Chanakya. T004 (API layer) is
           already briefed and independent. Pick up T004 while waiting?"
```

**Back to Chanakya — processing and continuing:**

```
You:     /chanakya brief T002

Chanakya: [auto-sweeps inbox — finds T001 debrief]
          "Processed T001 debrief. Learnings:
           - CategoryModel was reusable (no new model needed)
           - 'Smart sort' still unresolved — added to blockers
           
          Now briefing T002...
          [reads T001's completed code to understand the integration point]
          [fetches Figma node 1:60100 for the grid design]
          [cross-references PRD sections 3.1–3.6]
          
          File overlap check: T002 will modify TemplateBrowserView.swift,
          which T001 already changed. No conflict — T001 is done.
          
          T002 brief ready. Key details:
          - PRD specifies infinite scroll with 20-item pages (3.2)
          - Figma shows 2-column grid with 8pt spacing, 180pt card height
          - Performance note: PRD says 500+ items possible (3.5) —
            brief includes LazyVGrid guidance from swiftui-performance-audit
          - Integration: reads selected category from T001's published filter
          
          Launch a worker?"
```

**The cycle continues** — each brief combines PRD requirements (the "what" and "why"), Figma specs (the "how it looks"), and codebase context (the "where and how to build it"). Workers get everything they need in one file.

---

**Key points for PRD-heavy workflows:**

1. **Give Chanakya the PRD file path** — it reads the whole document and extracts requirements per task. You don't need to summarize it yourself.

2. **Give all Figma nodes upfront** — Chanakya maps them to tasks and fetches each one during brief generation, not all at once.

3. **Chanakya catches PRD gaps** — ambiguous requirements, missing specs, undefined algorithms. It flags them before workers hit them.

4. **PRD section references travel into briefs** — each brief cites the specific PRD sections (e.g., "PRD 3.2") so workers can trace requirements. If someone asks "why did you build it this way?", the answer traces back to the spec.

5. **Phasing by dependency** — Chanakya identifies which tasks need backend endpoints and which can start immediately with mocks. No one waits unnecessarily.

6. **Figma + PRD merge** — the acceptance criteria in each brief combine visual requirements (from Figma) with functional requirements (from PRD). Workers don't need to cross-reference two sources.

---

## File System

After a typical feature lifecycle, here's what the file tree looks like:

```
~/.dev-studio/<project>/plans/
  chanakya-master.md                          # The master plan
  user-testing.md                             # Consolidated manual-test file (on demand)
  user-testing-archive/                       # Past manifests after review-feedback
  chanakya-tasks/
    T001-export-settings.md                   # Brief (written by Chanakya)
    T002-format-selection.md
    T003-share-sheet.md
    T004-progress-indicator.md
    T005-watermark.md
    T006-export-history.md
  chanakya-inbox/
    direct-xyz7890-debrief.md                 # Unprocessed ad-hoc debrief
    processed/
      T001-debrief.md                         # Processed by Chanakya
      T002-debrief.md
      T003-debrief.md
      ...
```

---

## Tips

1. **Start small.** Try `/achilles` on a bug fix first. Then try `/chanakya` on a small feature. Scale up as you get comfortable.

2. **Chanakya always suggests next steps.** Just say "yes" to keep moving. Say "do T003 instead" to redirect. Say "I'm done for now" to stop.

3. **Achilles picks its own next task.** After finishing work, it reads the master plan and suggests what to do next. You don't need to remember task IDs.

4. **Briefs are snapshots.** If the codebase changes significantly between briefing and execution, Achilles may flag stale references. Just regenerate the brief with `/chanakya brief T001`.

5. **Debriefs are where knowledge lives.** The Key Learnings section in debriefs feeds into project memory. Be generous with feedback — tell Achilles what was tricky, what was surprising, what future sessions should know.

6. **Use parallel workers for independent tasks.** If T003, T004, and T005 are all briefed and independent, run three Achilles sessions in three terminal tabs. They won't conflict.

7. **PRD changes mid-flight are normal.** Use `/chanakya review` to diff the changes against existing tasks. Chanakya tells you exactly what's affected and what needs re-briefing.

8. **Not everything needs a plan.** A one-line crash fix doesn't need Chanakya. Just `/achilles` and describe the bug. The debrief still gets logged for tracking.
