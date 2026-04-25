---
name: Studio Release
description: Draft release notes per `RELEASES.md` template, evaluate if the repo has crossed a release-worthy threshold, and update README's Mermaid timeline + Story so far when a release actually ships. Never auto-tags.
type: mode-pack
schema_version: 1
budget_tokens: 1000
snapshots: []
reads:
  - RELEASES.md
  - README.md
  - git log since last tag
  - CHANGELOG or release notes history (if present)
writes:
  - release draft (chat output; user decides to tag)
  - README.md (only after a release actually ships)
---

# Mode: Release (Studio)

Fired when the user says "draft release notes", "what's new", "should we tag?", or "ship the studio". Walks `RELEASES.md` template + tone rules. **Never auto-tags.**

## Step 1 — Determine position

```bash
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null)
AHEAD=$(git log --oneline "$LAST_TAG"..HEAD 2>/dev/null | wc -l)
```

If `$LAST_TAG` is empty, this is a pre-v0.1 repo — ask the user what baseline to use.

## Step 2 — Read the rulebook

`RELEASES.md` is authoritative for:
- Template (what sections to include, in what order).
- Tone rules (outcome-first bullets, no marketing, no emojis unless asked).
- "When to tag" thresholds (MINOR vs. PATCH; MAJOR criteria for breaking changes).
- Which tiers of change go in which section.

Don't draft without consulting it. If the user invokes this mode without `RELEASES.md` having changed recently, the rule file still shapes the draft.

## Step 3 — Evaluate threshold (proactive case)

If the user invoked this mode *after* landing commits (not asking directly), check RELEASES.md's "When to tag" criteria:

- Crossed a threshold → surface one sentence suggesting a tag. Don't auto-tag.
- Not crossed → say so; don't spam a suggestion.

## Step 4 — Draft

Commits since last tag, grouped by RELEASES.md's template sections (Features / Improvements / Fixes / Breaking / etc.). Outcome-first bullet style — what the user gets, not what changed in the code.

Example shape:

```markdown
## v0.X.Y — <theme>

### Features
- Auto-refreshes the base branch pre-Argus so stale-base blocks don't fire on parallel merges.

### Improvements
- ...

### Fixes
- ...
```

## Step 5 — Wait

Do NOT run `git tag`, `gh release create`, or push. Present the draft; wait for the user to say "tag it" or "push it" or equivalent explicit go-ahead.

## Step 6 — Post-ship tasks (only after tag is live)

Per `CLAUDE.md`: when a release ships, update README.md:

1. Mermaid timeline — add a new line under the appropriate year.
2. "Story so far" — prepend a one-paragraph summary of the new release.
3. Remove any "Coming next" / "Long term" themes that the release just delivered.

Outcome-first bullets (same rules as RELEASES.md). Then commit the README update with a message like `README: vX.Y.Z timeline + Story so far update`.

## Never

- Tag without explicit user go-ahead.
- Push without explicit go-ahead.
- Draft without consulting RELEASES.md.
- Add emojis unless the user asked.
- Write marketing copy — outcome-first bullets only.

## Fixture

`tests/mode-packs/studio/release.yaml` — subagent must cite RELEASES.md as authoritative, refuse to tag without user input, and produce outcome-first bullets (not marketing copy).
