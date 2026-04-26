---
name: Chanakya Brief-Review
description: Checklist-driven quality pass over an authored brief before dispatch. Warn-tier, not block — ships even with findings. Catches brief defects that cascade into rework. Runs standalone via `/chanakya brief-review <task-id>`; not auto-invoked.
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md
budget_tokens: 1200
snapshots: []
reads:
  - plans/briefs/*.yaml                            # canonical brief
  - plans/tasks/<task-id>.yaml                     # parent task for context (type, size, links)
writes:
  - events/<date>.jsonl                            # brief_review_flagged event per run with findings
---

# Mode: Brief-Review (`/chanakya brief-review <task-id>`)

Walk the checklist below against the brief for `<task-id>`. Emit one `brief_review_flagged` event at the end with the finding count. **Warn-tier, not block** — a brief with findings is still dispatchable. This mode exists because a single anti-pattern in a root brief propagates to every inherited impl brief; catching it pre-dispatch is an order of magnitude cheaper than backporting fixes across a mid-flight task track (see issue #104 for the cascade that motivated this).

## Step 1 — Load

Resolve via `scripts/task-load-spec.sh <task-id>`. If `TASK_MODE=direct` (no brief), report "direct-mode task — no brief to review" and exit clean. Otherwise read the brief at `$BRIEF_PATH`. Capture `$BRIEF_UUID`, `$SIZE`, `$TYPE` for event emission.

## Step 2 — Walk the checklist

Tag each finding with its ID. For each: quote the defect (1 line from the brief), state the impact, propose a fix. Don't rewrite the brief — the author decides whether to act.

### C1 — Acceptance criteria with binary exit conditions

Does the brief have an `## Acceptance` section? Is each bullet testable in binary pass/fail terms (not "should work smoothly", "feels right")? Flag subjective criteria.

### C2 — No prescriptive technical choices that are likely wrong

If the brief says "use `actor` here" or "cache in an `NSCache`", verify the choice against the surrounding code's existing conventions. Prescriptive tech that doesn't match the repo forces the worker to either (a) follow a bad recommendation, (b) re-derive and push back. Both waste time. Prefer "choose between X/Y based on …" over "use X" when the author isn't certain.

### C3 — Terminology disambiguation

Scan for terms that commonly confuse: `debounce` vs `throttle`, `lock` vs `latch` vs `semaphore`, `cache` vs `memoize`, `sync` vs `coordinate`, `retry` vs `idempotency-key`, `cancel` vs `invalidate`. If any appears, check whether the brief pins the precise semantic or leaves it to interpretation.

### C4 — Deliverable-path collision check

Does the brief name files the worker will **create** (not modify)? For each such file, check whether it already exists. A pre-existing artifact at a deliverable path is the "split merge" trap — worker overwrites vs. author-expected additive change.

### C5 — Task-ID leakage in behavioral acceptance

Acceptance bullets should describe user-visible behavior, not task metadata. "Feature gate toggles cleanly under T301-a's flag" is acceptance-rot; the user doesn't know about T301-a. Flag any `T\d+[a-z]?` appearing inside an acceptance bullet.

### C6 — Concurrency / memory / crash-recovery constraints

For any long-running task (`size: m|l`, `type: feature|refactor`), is there an explicit stance on: concurrent mutation safety, memory footprint ceiling, and behavior if the process is killed mid-operation? Silence on these three produces the class of bugs that surface only in production. A one-line "N/A — single-threaded UI path" is fine; absence is the hit.

### C7 — Scope fences

Does the brief say what is explicitly **not** in scope? A task without a "non-goals" or "out of scope" clause has unlimited surface area. Flag if none present.

### C8 — Readability of the body

Is `body:` a YAML block-scalar (`body: |`), not a flat-escaped string? Flat-escaped body is the brief-writer regression from #105; it renders to garbage markdown. Check: the first line of `body:` after the key should be a literal `|`, and subsequent lines should indent by 2 spaces.

### C9 — Figma / design reference staleness

If the brief cites a Figma node id, was the node fetched and inlined (not just linked)? A brief that says "see Figma node 1:533" without the rendered description assumes the worker has MCP access — often wrong. Inlined context is the rule.

### C11 — Model + reasoning effort recommendations present and sensible

Per `_shared/rules/brief-model-effort.md`, every brief MUST declare three fields in the Priority & Complexity / Recommendations block: `Recommended model` (Opus / Sonnet / Haiku), `Model reasoning effort` (low / medium / high), and `Size` (XS / S / M / L). Each must carry a one-line rationale.

Two flag conditions:

1. **Missing field** — any of the three absent. Flag and request the author add it before dispatch.
2. **Sniff-test failure** — the choice is structurally wrong:
   - `Haiku` on a cutover / migration / crash root-cause / architecture decision (Opus territory).
   - `Opus` on a one-line guard / flag flip / rename-only refactor (Haiku territory).
   - `Haiku / high` (cost mismatch — `high` reasoning needs `Sonnet` or `Opus` to be useful).
   - Rationale missing or generic ("seems right" / "default") — the rule requires a one-line rationale specific to THIS task.

Surface as a finding; don't auto-correct. The author owns the recommendation.

## Step 3 — Emit event + report

Count findings. Emit one event:

```bash
source scripts/lib-paths.sh
source scripts/lib-ledger.sh

finding_count=<N>
finding_list='C1,C4,C7'          # comma-joined IDs of flagged checks, or empty
data=$(printf '{"brief_uuid":"%s","finding_count":%s,"findings":"%s","size":"%s","type":"%s"}' \
  "$BRIEF_UUID" "$finding_count" "$finding_list" "$SIZE" "$TYPE")
emit_event_keyed chanakya brief brief_review_flagged "$BRIEF_UUID" "$data"
```

Report:

> *"Brief-review for T123: 2 findings (C4 — deliverable-path collision on PhotoEditorView.swift; C7 — no non-goals section). Warn-tier — brief is still dispatchable. Author can `/chanakya brief T123` to re-author, or dispatch as-is with `/achilles T123`."*

Zero findings: `"Brief-review for T123: 0 findings. Brief is clean."`

## Non-goals

- **Not a block.** The event is informational. Achilles is free to pick up a brief with findings.
- **Not a rewrite.** Report findings; don't edit the brief. Author owns revisions.
- **Not an Argus substitute.** Argus reviews code diffs post-implementation. Brief-review looks at the spec pre-implementation. Independent gates.

## Checklist evolution

This file *is* the memory for brief defects. When a real-world rework shows a pattern this checklist missed, add the pattern here (tight — one bullet per C-item, one paragraph of rationale). When a C-item over-flags for multiple cycles, downgrade or delete. Cheap to edit, expensive to let rot.
