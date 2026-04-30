---
name: Brief model and effort recommendations
description: How brief authors (Chanakya today, Lu Ban tomorrow) pick the recommended model + reasoning effort + task size for a brief. Required fields per the brief-format templates.
type: reference
schema_version: 1
---

# Brief model + effort recommendations

Every brief author MUST emit three orthogonal fields in the brief's "Priority & Complexity" / "Recommendations" block. These fields drive worker dispatch and let the user triage parallelism by cost.

## The three fields

| Field | Values | Drives |
|---|---|---|
| `Recommended model` | `Opus` / `Sonnet` / `Haiku` | Which model the worker session runs on |
| `Model reasoning effort` | `low` / `medium` / `high` | Thinking-budget tier on top of the model |
| `Size` (a.k.a. task effort) | `XS` / `S` / `M` / `L` | Step 6 build gate (XS/S → LSP-only, M/L → full build) |

The first two govern **thinking cost**. The third governs **diff cost**. They are independent:

- A small (`S`) crash fix can warrant `Opus / high` because diagnosis is the cost driver, not the diff.
- A large (`L`) mechanical refactor (rename across N files) can warrant `Sonnet / low` because the work is well-specified and pattern-matchable.

## Model defaults by task shape

Pick one when you author the brief, or run `scripts/recommend-model.sh` for the structured `recommended_models` payload. Override with rationale.

| Task shape | Default model | Why |
|---|---|---|
| Cutover, migration phase, schema change | Opus | Cross-module reasoning, hard to undo if wrong |
| Crash root-cause, intermittent bug | Opus | Diagnosis is the cost, not the diff |
| Architecture decision baked into the task | Opus | One-shot decisions reverberate |
| Implementation against a clear spec, established pattern | Sonnet | The common case; spec + reference exemplar shrink the search |
| Test authoring with template + working impl | Sonnet | Patterns established; failure modes scoped |
| Flag flip, string change, one-line guard | Haiku | Mechanical; reasoning budget wasted |
| Rename-only refactor across files | Haiku | LSP-driven; no judgment calls |
| Formulaic test scaffolding off a fixture | Haiku | Templated; no architectural decisions |

## Reasoning effort tiers

| Effort | When |
|---|---|
| `low` | Mechanical work; clear path; no ambiguity |
| `medium` | Standard implementation against a spec; some choices to make |
| `high` | Cutovers, root-causing, novel architecture, ambiguous spec |

`high` on Haiku is rarely correct — if reasoning budget needs to be `high`, the model probably needs to be `Sonnet` or `Opus`. Brief-review (Chanakya) flags this combination.

## Field placement

In the brief's "Priority & Complexity" (impl) or "Recommendations" (test) block, alongside Priority / Branch / Type / Size. Each line carries a one-line rationale — what about THIS task drove the choice.

## Validation

`chanakya/modes/brief-review.md` includes a checklist item that confirms all three fields are present and pass a sniff test:

- ✗ Don't send `Haiku` at a cutover.
- ✗ Don't send `Opus` at a one-line guard.
- ✗ Don't pair `Haiku / high` (cost mismatch — `Sonnet / medium` or `Sonnet / high` is the right call).

Briefs failing the sniff test are flagged warn-tier — they ship, but with a finding that surfaces in `/chanakya brief-review`.

## Surface in status

When Chanakya lists candidate tasks for dispatch, annotate them with model + effort so the user can plan parallelism by cost:

```
Train 3 crash fixes: T272 (Opus / high, S), T273 (Opus / high, S), T276 (Opus / high, S)
Quick polish: T280 (Haiku / low, XS), T281 (Haiku / low, XS)
```

`modes/status.md` is the canonical render surface for this annotation.

## Cross-agent

Today only Chanakya authors briefs. When Lu Ban (the planned architect agent — see ROADMAP §Phase 4) ships, it inherits the same rule by reading from this file. Briefs landing without these fields fail brief-review regardless of author.

## See also

- `_shared/rules/model-recommendation.md` — deterministic structured recommendation rule.
- `_shared/schemas/model-catalog.yaml` — hand-maintained tier-to-model catalog.
- `_shared/rules/model-policy.yaml` — default preference for consumers.
- `_shared/contracts/brief-formats/*.md` — the templates that surface these fields.
- `chanakya/modes/brief.md` — the mode pack that emits briefs; Step 6 enforces.
- `chanakya/modes/brief-review.md` — the checklist that validates.
