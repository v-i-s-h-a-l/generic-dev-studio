---
name: Studio Ingest
description: Studio-level ingest — inputs that concern the studio's own evolution (analysis reports from running on real projects, pattern observations, parking-lot candidates) rather than user-project feedback. Routes user-project feedback to `/chanakya ingest-*` instead.
type: mode-pack
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

## Step 2 — Privacy check (for any public output)

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

## Step 3 — Act on the classification

- **Abstract pattern** → `gh issue create --title ... --body ... --label <enhancement|bug|phase-2|roadmap|polish>` per `CLAUDE.md` §Backlog.
- **Raw analysis** → write to `~/.dev-studio/<project>/analysis/<date>.md`. Never `git add` this file.
- **Parking-lot candidate** → append entry to `studio-consolidation/parking-lot.md` with date + rationale.
- **Direct rule change** → in-place edit + commit.

## Step 4 — Confirm

One-line summary of what happened, link to the artifact (issue URL for (1), file path for (2)/(3), commit for (4)).

## Fixture

`tests/mode-packs/studio/ingest.yaml` — subagent must correctly classify across the four output paths and apply the privacy scrub before opening any public issue.
