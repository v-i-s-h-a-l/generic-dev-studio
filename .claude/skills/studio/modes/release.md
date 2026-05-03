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

## Step 3 — Evaluate threshold + decide bump

Check RELEASES.md's "When to tag" criteria against the commits since last tag.

- **Not crossed** → say so in one sentence; stop. Don't spam a suggestion.
- **Crossed** → determine the version bump from RELEASES.md. Use PATCH for fixes and for narrow follow-ups to the current release arc; use MINOR for broader additive or breaking pre-1.0 changes. Continue to Step 4. No separate "should we tag?" prompt — the user already asked for a release.

## Step 4 — Draft, tag, release, update README (single pass)

When threshold is met, execute the full release in one shot:

1. **Draft** release notes to `/tmp/vX.Y.Z-notes.md` per RELEASES.md template. Outcome-first bullets.
2. **Tag**: `git tag -a vX.Y.Z -m "vX.Y.Z — <theme>"` (annotated).
3. **Push tag**: `git push origin vX.Y.Z`.
4. **Create GH release**: `scripts/studio-gh.sh release create vX.Y.Z --notes-file /tmp/vX.Y.Z-notes.md --title "vX.Y.Z — <theme>"`.
5. **Update README.md**: Mermaid timeline line + "Story so far" paragraph + remove delivered "Coming next" themes.
6. **Commit + push README**: `README: vX.Y.Z timeline + Story so far update`.

Present the draft inline for the user to read, but don't pause between steps. The release is live by the time the user sees the output.

**If the user says "go ahead" or "tag it" after seeing a draft from a prior invocation**, skip re-drafting — execute steps 2–6 immediately.

## Pause only when

- Pre-1.0 MAJOR → confirm with user (rare, high-consequence).
- Ambiguous bump (could be MINOR or PATCH) → state the tradeoff in one sentence, pick the conservative one, proceed.
- No tag-worthy commits → stop after Step 3.

## Never

- Draft without consulting RELEASES.md.
- Add emojis unless the user asked.
- Write marketing copy — outcome-first bullets only.
- Ask "want me to draft?" or "should I tag?" — the user invoked `/studio release`, that IS the go-ahead. Execute the full pipeline.

## Fixture

`tests/mode-packs/studio/release.yaml` — subagent must cite RELEASES.md as authoritative, refuse to tag without user input, and produce outcome-first bullets (not marketing copy).
