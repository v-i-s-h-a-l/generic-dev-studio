---
name: Studio Ingest
description: Studio-level ingest — inputs that concern the studio's own evolution (analysis reports from running on real projects, pattern observations, parking-lot candidates) rather than user-project feedback. Routes user-project feedback to `/chanakya ingest-*` instead.
type: mode-pack
schema_version: 1
budget_tokens: 800
snapshots: []
reads:
  - ~/.dev-studio/<project>/analysis/*.md (private analysis reports)
  - studio-consolidation/parking-lot.md (if arc active)
writes:
  - GitHub issues (abstract patterns only, privacy-scrubbed)
  - studio-consolidation/parking-lot.md (if arc active; append-only)
  - ~/.dev-studio/<project>/analysis/<date>.md (private, never committed)
---

# Mode: Ingest (Studio)

Fired when the user wants to capture input about the **studio itself** — not feedback about the user's iOS project. Examples:

- "I noticed Argus always flags test fixtures as secrets — that's a false positive pattern."
- "Here's an analysis I ran on how we used the studio this week."
- "Add this to the parking lot: we might want a synthetic-QA agent after Phase 5."

For user-project feedback (bug reports, product/design notes, Slack thread ingestion), route to `/chanakya ingest-thread`, `/chanakya ingest-dm`, `/chanakya ingest-slack`, or `/chanakya studio-feedback` instead.

## Step 1 — Classify the input

One of:

1. **Abstract pattern** (distilled from real usage, no project-specific details): GitHub issue on `generic-dev-studio`. Anonymous phrasing. Actionable — propose a change or a next action.
2. **Raw analysis** (detailed citations from a real run): private file at `~/.dev-studio/<project>/analysis/<date>.md`. Never committed. Input to future pattern distillation.
3. **Parking-lot candidate** (arc-relevant, but not the current synthesis moment): append to `studio-consolidation/parking-lot.md` per `00-plan.md` no-cascade rule. Only if an arc is in flight.
4. **Direct rule change** (auto-apply tier per CLAUDE.md): edit `REVIEW.md` / `RELEASES.md` / `CLAUDE.md` / `THEMES.md` in-place, commit with `review: <note>` or similar.

If the input is ambiguous, ask which classification fits — one sentence. Do not guess.

## Step 2 — Shape before capture

Before writing an issue, parking-lot entry, private analysis note, or direct rule change, run a lightweight request-shaping pass when the input is a feature idea, bug-fix request, workflow proposal, or planning prompt.

Do not merely transcribe weak or underspecified input. Help the user get a better implementation by adding the missing structure that is visible from context:

- clearer goal and user impact
- suggested scope cuts or routing to the right agent/layer
- acceptance criteria and non-goals
- behavior before / behavior after / new behavior
- edge cases and adjacent use cases that could affect implementation, tests, rollout, cleanup, or user-facing messaging

If the improvement is obvious and low-risk, fold it into the captured artifact. If it changes behavior, cost, priority, runtime risk, or ownership, surface it to the user before acting. Keep the original intent intact; refine the request, do not replace it.

This is a process rule for ingest itself: when the user says "ingest this" and the material would benefit from direction, suggestions, or edge-case thinking, provide that guidance instead of silently storing a shallow note.

## Step 3 — Privacy check (for any public output)

Per `CLAUDE.md` §Analysis sessions and privacy: strip everything project-specific before publishing. Self-check: *if this text were posted to a competitor's Slack, would anything embarrassing or proprietary leak?*

Specifically never include in public output:
- Task IDs, feedback-record IDs.
- Debrief/review text quoted verbatim.
- Slack channel names, @mentions.
- Commit messages / branch names from the work project.
- File paths from the user's project.
- Build numbers, TestFlight versions.
- Feature names, user names.
- Performance / velocity numbers.

If the input came verbatim from a user-project artifact and you can't cleanly anonymize, route to classification 2 (private) instead of 1 (public issue).

## Step 4 — Act on the classification

- **Abstract pattern** → `gh issue create --title ... --body ... --label <enhancement|bug|phase-2|roadmap|polish>` per `CLAUDE.md` §Backlog.
- **Raw analysis** → write to `~/.dev-studio/<project>/analysis/<date>.md`. Never `git add` this file.
- **Parking-lot candidate** → append entry to `studio-consolidation/parking-lot.md` with date + rationale.
- **Direct rule change** → in-place edit + commit.

## Step 5 — Confirm

One-line summary of what happened, link to the artifact (issue URL for (1), file path for (2)/(3), commit for (4)).

## Fixture

`tests/mode-packs/studio/ingest.yaml` — subagent must correctly classify across the four output paths, shape underspecified requests before capture, and apply the privacy scrub before opening any public issue.
