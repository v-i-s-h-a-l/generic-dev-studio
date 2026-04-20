---
description: Resume the architecture refactor — read roadmap + memory, report current state, ask pending questions
allowed-tools: [Bash, Read]
---

# Resume plan

Load the current state of the multi-session architecture refactor and report where we are.

## Steps

1. Read `ROADMAP.md` — focus on the "Phase sequence" section at the bottom.
2. Read `ARCHITECTURE.md` — focus on "Design Vision (2026-04-20 synthesis)".
3. Check for pending memory questions:

   ```bash
   MEM_DIR="$HOME/.claude-personal/projects/$(pwd | tr '/.' '-' | sed 's/^-//')/memory"
   ls "$MEM_DIR"/project_*_pending.md 2>/dev/null
   ```

   Read each; they describe questions the previous session explicitly left for this one.

4. Check git state:

   ```bash
   git branch --show-current
   git log --oneline main..HEAD 2>/dev/null | head -20
   ```

5. Report to the user, in this order:
   - Current branch + commits ahead of main.
   - Last completed phase (from ROADMAP §Phase sequence → Completed).
   - Next planned phase (from ROADMAP §Phase sequence → Planned, first entry).
   - Any pending memory questions — ask them explicitly.

6. After asking, wait for the user's answer before proceeding with any phase work.
