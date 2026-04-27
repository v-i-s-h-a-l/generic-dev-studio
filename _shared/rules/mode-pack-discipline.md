---
name: mode-pack-discipline
description: Authoritative rule for what may live in a mode pack and what must be referenced from _shared/. Enforced by scripts/lint-mode-pack.sh (pre-commit Gate 2e) and REVIEW.md R19.
type: rule
schema_version: 1
---

# Mode pack discipline

Authoritative rule for what may live in a `<agent>/modes/*.md` file and what must be referenced from `_shared/`. Enforced by `scripts/lint-mode-pack.sh` (run by pre-commit Gate 2e and REVIEW.md R19).

## Why

Routers stay nominally lean while their mode packs absorb every concept the router used to inline. Mode packs become bloated copies of `_shared/contracts/`, `_shared/rules/`, `_shared/primitives/`, and `_shared/schemas/` content. Each restatement drifts independently. The fix is structural: **the lint refuses to commit a mode pack that duplicates shared content or exceeds its declared budget.**

## Rules

### MP1 — `budget_tokens` is load-bearing

Every `*/modes/*.md` MUST declare `budget_tokens: <int>` in frontmatter. The lint computes an estimate (`chars / 4`, the Anthropic-published heuristic) and blocks when the estimate exceeds the budget. There is no "advisory" tier — the budget is a contract.

If a mode pack genuinely needs more tokens, raise `budget_tokens` in the same commit and justify in the commit message. Reviewers may push back on the increase; that is the correct conversation.

### MP2 — No inline restatement of `_shared/` content

Detected as: 4+ consecutive significant lines (length ≥ 40 chars, non-blank, non-heading) that match exactly any paragraph found in `_shared/contracts/*.md`, `_shared/rules/*.md`, `_shared/primitives/*.md`, or `_shared/schemas/*.md`.

Fix: replace the inlined block with a reference of the shape `See _shared/<area>/<file>.md` pointing at the canonical primitive.

Escape hatch: if a duplicate is intentional and load-bearing, add a sentinel comment immediately above the matching block:

```
<!-- shared-dup-allowed: <one-sentence reason> -->
```

The lint records the reason but does not block.

### MP3 — Router cap

`<agent>/SKILL.md` MUST be ≤ 80 non-blank, non-comment lines. Routers exist to dispatch — anything load-bearing belongs in a mode pack or a `_shared/` artifact.

### MP5 — Retired-pattern gate (cross-agent, block)

`_shared/rules/retired-patterns.md` catalogs behavioral patterns that have been retired from scripts, libs, or shared contracts. `lint-mode-pack.sh` reads the ERE list from that file and blocks on any match in any `*/modes/*.md` or `*/SKILL.md` across all agents.

**When a script retires a write path or behavioral contract:** add the grep pattern to `_shared/rules/retired-patterns.md` in the same commit and run the lint to catch and fix all existing hits. R21 (REVIEW.md) is the human gate for paraphrased references the grep can't see.

This check is intentionally cross-agent. Retired patterns don't respect agent boundaries — a pattern retired from lib-ledger can show up in Achilles, Argus, Chanakya, or Apollo mode packs. The lint sweeps all of them.

### MP4 — Grandfather list

`scripts/lint-mode-pack-grandfather.txt` lists files known to violate MP1/MP3 with a target cleanup date. Listed files emit a warning instead of a block until their date passes. Once the date is in the past, the lint blocks regardless. Format documented at the top of the grandfather file.

The grandfather list is not an indefinite reprieve — entries without a target date are rejected by the lint itself.

## Interaction with other rules

- **R8** (token-cost awareness for skill prose) is the soft sibling — applies to all SKILL.md / mode prose at review time. MP1 is the hard floor: it blocks at commit time.
- **R18** (Skill Authoring Standard) operates on grammar and frontmatter shape via `lint-skill-prose.sh`. MP1–MP5 operate on token economics, inline duplication, and retired-pattern hygiene. The two linters compose; both run in pre-commit.
- **R19** (REVIEW.md) is the prose-level gate for human reviewers; the lint is the structural enforcement.
- **R21** (REVIEW.md) is the companion rule for MP5: it requires updating `retired-patterns.md` whenever a script retires a behavioral pattern.
