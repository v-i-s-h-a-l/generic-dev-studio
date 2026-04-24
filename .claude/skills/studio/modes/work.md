---
name: Studio Work Mode
description: Autonomous issue worker for a parallel track. Claims the next unassigned issue in the track, implements it on the track branch, commits, closes the issue, and loops. Entry point for /studio work <track> or STUDIO_TRACK env var auto-start.
type: mode-pack
budget_tokens: 600
reads:
  - TRACKS.md
  - scripts/track-next.sh output
writes:
  - track branch commits
  - GH issue state (assign + close)
---

# Mode: Work

Autonomous worker for a named parallel track. Runs a pick → implement → commit → close loop until the track is complete or the user interrupts.

## Entry

Triggered by:
- `/studio work <track>` — explicit invocation
- `STUDIO_TRACK=<track>` env var at session start (SessionStart hook injects the first directive automatically; subsequent issues loop via this mode)

## Step 1 — Identify track

From the arg or `STUDIO_TRACK` env var. Validate against `TRACKS.md` (branch must exist, label must exist).

## Step 2 — Claim next issue

Run `scripts/track-next.sh <track>`.

- Exit 0: directive printed — read it, proceed to Step 3.
- Exit 1 (`TRACK_COMPLETE`): all issues done. Report to user, stop.

The script handles branch checkout, `git pull`, GH assignment atomically. Do not repeat those steps manually.

## Step 3 — Implement

Read the issue body. It is the full spec — acceptance criteria, scope, files to touch. Implement exactly that scope. No more.

**Studio repo work (not iOS):** implement directly — write scripts, edit mode packs, update SKILL.md, add fixtures. Do not spawn Achilles.

**File ownership rule:** only touch files in this track's ownership column in `TRACKS.md`. If an implementation requires a file owned by another track, stop and surface to the user instead of editing it.

## Step 4 — Review gate

Before committing: if the diff touches any `scripts/*.sh`, `SKILL.md`, or `_shared/*` file, or is >100 lines — walk `REVIEW.md` rules. Auto-fix `block+auto-fix` tier silently. Surface `ask` tier before changing. Note `warn` tier in commit message.

## Step 5 — Commit

Commit to the track branch (`track/<name>`), not `main`. Commit message: one-line summary + `Closes #N` trailer. Co-author line.

```
git commit -m "$(cat <<'EOF'
<summary>

Closes #N
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

## Step 6 — Close issue

```
gh issue close <N> --comment "Implemented in $(git rev-parse --short HEAD) on track/<name>."
```

## Step 7 — Loop

Run `scripts/track-next.sh <track>` again. If exit 0, go to Step 3. If exit 1, track is complete — report and stop.

Print a one-line checkpoint after each closed issue so the user can interrupt:
```
✓ #N closed. Picking next issue...
```

## When to stop without completing

- File ownership conflict (Step 3)
- Review gate surfaces an `ask`-tier finding (Step 4)
- Build/test failure that needs user judgment
- `TRACK_COMPLETE` (Step 7)

In all cases: report clearly what was done, what was left, and what the user needs to decide.

## Cross-track dependency

If an issue body says `Blocked by: #N` and #N is still open, skip that issue (do not assign it), try the next one. If all remaining issues are blocked, stop and report.
