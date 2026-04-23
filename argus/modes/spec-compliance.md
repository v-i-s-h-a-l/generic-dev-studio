---
name: Argus Spec-Compliance
description: Stage 1 of the two-stage Argus review. Narrow check — does the diff match the brief? Nothing extra, nothing missed. Runs before code-quality. Drawn from obra/superpowers/subagent-driven-development.
type: mode-pack
snapshots: []
budget_tokens: 1200
reads:
  - plans/briefs/<brief-id>.yaml                   # what the task was supposed to do
  - plans/tasks/<task-id>.yaml                     # size + type context
  - plans/chanakya-tasks/<task-id>-*.md            # legacy brief fallback
writes:
  - events/<date>.jsonl                            # review_requested (stage: spec), review_{approved,flagged,blocked} (stage: spec)
---

# Mode: Spec-Compliance (Argus Stage 1)

**Narrow question: does the diff implement exactly what the brief asked for — no more, no less?**

Spec-compliance runs first. On `pass`, Chanakya (or Achilles) then dispatches Stage 2 (`code-quality`). On `fail`, code-quality is skipped — the diff is wrong at the spec level and re-running code checks burns tokens without adding signal.

## Why split from code-quality

`obra/superpowers/subagent-driven-development` measured single-pass review conflates "matches the spec" with "code is good", causing over-building (extra scope snuck in, flagged as "nice refactor") and under-building (missing requirement from the brief, missed because the reviewer is in code-quality headspace).

Separating them forces the reviewer to pass the narrow judgment first:

> *"Ignoring code style, edge cases, and diff hygiene — does this diff do exactly the thing the brief asked for, and nothing else?"*

## Invocation

Invoked by Achilles Step 8.5 as the first of two Argus calls, or standalone:

```
/argus spec-compliance [<task-id>]
```

Standalone inference: branch name → task id → brief path.

## Checks (in order)

### Check 1 — Scope match

Read the brief's `what` / `requirements` sections. Cross-reference against `CHANGED_FILES` from `scripts/argus-diff-extract.sh`:

- **Extra scope** — changed files NOT mentioned or implied by the brief. Exception: pure test files paired with an implementation file that IS in scope. Exception: file moves Git tracks as rename/delete.
- **Missing scope** — brief mentions a file / module / requirement, but no change landed there. Flag if the brief's language is firm ("add X", "wire up Y"); allow if soft ("consider doing Z").

### Check 2 — Requirement coverage

For each numbered requirement / acceptance criterion in the brief, answer yes/no: did the diff fulfill it? A requirement that says "add telemetry for event X" is satisfied iff there's a call to the telemetry library with that event name — not just a comment mentioning it.

Missing requirements → `blocked` (spec-level failure).

### Check 3 — Over-building

Signals that the diff goes beyond the brief without authorization:
- Refactor of a module the brief didn't name.
- New abstraction (`Protocol`, `interface`, `trait`) when the brief asked for a concrete implementation.
- "Drive-by" improvements in unrelated files — formatting, rename, extract — that create review noise.

Over-building → `flagged` unless the brief explicitly invited follow-on cleanup.

### Check 4 — Under-building

Signals that the diff stopped short:
- Brief asked for tests; no new test files.
- Brief asked for error handling; error paths absent.
- Brief named a state transition; transition event missing from `events/<date>.jsonl`.

Under-building → `blocked` if a firm requirement is missed; `flagged` for soft ones.

### Check 5 — Brief-diff semantic coherence

Does the code's naming match the brief's vocabulary? A brief asking for `FilterPresetStore` landing as `PresetFilterManager` is a cohesion flag — downstream consumers (docs, other tasks) expect the brief's name.

Lightweight check. Flag; never block.

## Verdict

```
Any requirement missed (Check 2 or 4 firm)  → blocked
Extra scope (Check 1)                       → flagged
Over-building (Check 3)                     → flagged
Soft under-building (Check 4 soft)          → flagged
Vocabulary drift (Check 5)                  → flagged
All clean                                   → approved
```

**No test run, no cross-file scan, no secrets check, no base-staleness check.** Those are Stage 2's job. Spec-compliance is diff-only, typically completes in seconds.

## Event emission

```bash
scripts/argus-emit-verdict.sh "$TASK_ID" "$VERDICT" "$FINDINGS_JSON" \
  --stage spec \
  --task-uuid "$TASK_UUID" [--block-reason "$REASON"]
```

The `--stage spec` flag marks the `review_approved` / `review_flagged` / `review_blocked` event with `stage: spec` so Chanakya's sweep knows Stage 2 is still pending.

## Handoff to Stage 2

Stage 2 (`code-quality`) runs iff Stage 1 verdict is `approved` or `flagged`. On `blocked`, skip Stage 2 — the spec is wrong; fix that before re-reviewing.

Achilles Step 8.5 implements the sequencing:

```
Invoke Argus (spec-compliance)
├─ blocked → feed block_reason to Achilles; no code-quality run; debrief report_state=blocked or done_with_concerns
├─ flagged → record findings; continue to code-quality
└─ approved → continue to code-quality
```

## Scope caps (inherited)

Same 500-line diff load cap as `code-quality`. No separate cross-file scan (that's Stage 2).

## Behavior rules

1. **Never run `xcodebuild`.** Spec-compliance is diff-only.
2. **Never promote a code-quality finding to spec-compliance.** If the diff is ugly but implements the brief exactly, Stage 1 is `approved`; ugliness is Stage 2's signal.
3. **Brief missing or empty?** Return `blocked` with reason `brief-empty` — the task should never have been dispatched without a brief.
4. **Direct-debrief mode** (no brief): spec-compliance is N/A; skip this stage entirely.

## Skip threshold

Same XS-trivial skip as code-quality: diff <20 lines, single file, task size XS → skip both stages.

## Model

Opus. Same reasoning-heaviness as code-quality — judgment about firm-vs-soft requirements doesn't downgrade.

## Cross-refs

- `argus/modes/code-quality.md` — Stage 2.
- `_shared/rules/review-rules.md` — full check table (shared with code-quality).
- `_shared/schemas/review.md` — `review@1.1.0` adds `stage: spec | quality` field.
- `_shared/contracts/events.md` — `review_*` events carry `stage`.
