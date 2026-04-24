---
name: Studio Review
description: Walk `REVIEW.md` at the repo root against the current diff. Auto-fix `block + auto-fix` tier, surface `ask` tier before changing, note `warn` tier. For the studio's own repo — not the user's iOS project (that's Argus's job).
type: mode-pack
budget_tokens: 1200
snapshots: []
reads:
  - REVIEW.md
  - diff under review (via `git diff`)
  - _shared/** (when diff touches it, for cross-ref)
writes: []
---

# Mode: Review (Studio)

When the user asks "review this", "check this diff", "any issues?", or invokes `/simplify` on a studio-repo change, walk `REVIEW.md` against the pending diff. This mode is for the **studio's own rules** (R1–R11 in `REVIEW.md`); for the user's iOS project code review, route to `/argus` instead.

## Step 1 — Decide if review fires

Per `CLAUDE.md`: trigger review for any `scripts/*.sh` change, any `SKILL.md` change, any `_shared/*` change, or diffs >100 lines. Single-line doc fixes skip.

```bash
CHANGED=$(git diff --name-only HEAD 2>/dev/null)
LINES=$(git diff --shortstat HEAD 2>/dev/null | awk '{print $4+$6}')
```

If no triggers hit, say so and exit — don't burn tokens on a trivial diff.

## Step 2 — Walk each rule

Load `REVIEW.md` and for each rule (R1–R11), check against the diff:

1. Does the diff hit the rule's "How to check" procedure?
2. If yes, classify finding by tier (block+auto-fix / ask / warn).
3. Record finding with file:line where applicable.

## Step 3 — Act by tier

- **`block + auto-fix`** — fix it silently in the same change. Mention in the eventual commit message.
- **`ask`** — surface to the user before changing. Describe the tradeoff. Wait for decision.
- **`warn`** — note one line; fix unless the user says otherwise.

## Step 4 — Report

Structured output — one section per tier hit:

```
## Review findings

### Auto-fixed (block tier)
- R3: scripts/foo.sh:12 — hardcoded `~/.dev-studio/bar/` → resolver call.

### Ask before changing (ask tier)
- R1: scripts/bar.sh:34 adds a write to `/tmp/new-path/` — outside `~/.dev-studio/**`.
  Tradeoff: ...

### Warnings (warn tier)
- R6: scripts/baz.sh changed flag names but README.md snippet still shows old.
```

If all findings were block-tier auto-fixes, one-line summary is fine — don't over-report.

## Step 5 — Commit-message note

Per `CLAUDE.md` §Reviews: "Findings go in chat (ask-tier) and in the commit message (all tiers noted)." The user's commit message should include a one-line note of what the review caught, e.g. `review: R3 auto-fix (path resolver); R6 warn (readme drift).`

## Rule-evolution hook

If a finding recurs across reviews and `REVIEW.md` doesn't capture it, the user can ask to amend REVIEW.md — that's a separate change, not part of this review.

## Retroactive reviews are a failure mode

If the user asks for review *after* committing, note that — the rule file exists to shape the commit, not audit it afterward. Still walk the rules against the just-landed diff, but surface the process gap.

## Fixture

`tests/mode-packs/studio/review.yaml` — subagent must correctly identify which rules fire on a given diff and apply the tier-driven response.
