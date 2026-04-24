---
name: Studio Resume-Plan
description: Report where the studio's multi-session architecture arc is, and ask any pending questions the previous session left. Authoritative procedure — the thin `.claude/commands/resume-plan.md` slash command forwards to this mode.
type: mode-pack
budget_tokens: 800
snapshots: []
reads:
  - ROADMAP.md
  - ARCHITECTURE.md
  - CLAUDE.md
  - ~/.claude-personal/projects/<project-hash>/memory/MEMORY.md
  - ~/.claude-personal/projects/<project-hash>/memory/project_*_pending.md
  - studio-consolidation/00-plan.md (if present)
  - studio-consolidation/latest exit artifact (if present)
writes: []
---

# Mode: Resume-Plan

Entry point when the user asks "where were we" or invokes `/resume-plan`. Goal: fresh-context picker-up. Report state, surface pending questions, stop and wait for the user. Do not start phase work.

## Step 1 — Detect which plan is in flight

Two possible plans at any time:

1. **Multi-session architecture arc** (`studio-consolidation/`) — the current default. Exit artifacts numbered `00-plan.md`, `01-audit.md`, `02-research.md`, `03-target-architecture.md`, `04-approved.md`, etc.
2. **Roadmap phase sequence** (`ROADMAP.md §Phase sequence`) — older / parallel track.

If `studio-consolidation/` exists with unsigned-off artifacts (last `NN-something.md` that is not `04-approved.md` or later): the arc is in flight. Default to reporting the arc.

If the arc is fully signed-off (last artifact is `04-approved.md` followed by F-track commits on `main`): fall through to the roadmap phase sequence.

## Step 2 — Read the right anchor

**Arc mode:**
- Latest numbered exit artifact (`ls studio-consolidation/*.md | sort | tail -1`).
- `studio-consolidation/00-plan.md` for arc ground-truth.
- `studio-consolidation/parking-lot.md` if non-empty.
- Memory pointer `project_consolidation_arc.md`.

**Roadmap mode:**
- `ROADMAP.md` §Phase sequence (Completed + first Planned entry).
- `ARCHITECTURE.md` §Design Vision (2026-04-20 synthesis).

Always:
- `MEMORY.md` + any `project_*_pending.md` files in the memory dir.
- `git branch --show-current` + `git log --oneline main..HEAD | head -20`.

## Step 3 — Report in a fixed order

1. Branch + commits ahead of `main`.
2. Arc/phase state: last completed, next planned.
3. Pending memory questions — ask each explicitly.
4. Any parking-lot entries (arc mode only).

One sentence per bullet. Don't narrate discovery. Don't dump raw file contents.

## Step 4 — Stop

After asking, wait for the user's answer before proceeding with any phase work. Starting phase work before user input is the exact failure mode this mode exists to prevent.

## Error modes

- **No plan detected** (no `studio-consolidation/`, no ROADMAP Phase sequence section) → say so plainly; offer to start a new plan if the user wants.
- **Memory pending file points at an arc state that's been superseded** → report both, prefer the most recent commit-dated state.
- **Conflicting signals** (memory says arc done, git shows uncommitted `04-approved.md`) → surface the conflict; don't guess.

## Fixture

`tests/mode-packs/studio/resume-plan.yaml` — subagent pressure-tested on whether it correctly detects arc-vs-roadmap state, reports in the fixed order, and stops before doing phase work.
