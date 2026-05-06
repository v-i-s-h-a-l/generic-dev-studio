---
name: Requirement Packet
description: Compact normalized artifact produced from PRDs, transcripts, or issue briefs before planning.
type: contract
---

# Requirement Packet

`scripts/prd-intake-normalize.sh` writes a small Markdown packet that gives the
planner stable, reviewable input without decomposing work or dispatching
workers.

## Shape

The packet always contains these sections, in this order:

1. `Intake Metadata` - source label and extraction method.
2. `Explicit Requirements` - stated requirements with stable `R###` IDs.
3. `Inferred Behavior To Confirm` - inference signals with stable `I###` IDs.
4. `Stated Non-Goals` - out-of-scope language with stable `N###` IDs.
5. `Ambiguities And Missing Details` - ambiguous source lines (`A###`) plus
   deterministic missing-detail checks (`M###`).
6. `Conflicts` - contradictory stated requirements or requirement/non-goal
   collisions with stable `C###` IDs.

Every line-derived item quotes the exact source language. The script does not
rewrite the source into planner tasks and does not resolve conflicts.

## Extraction Discipline

- Preserve source order inside every section.
- Treat headings such as `Scope`, `Requirements`, and `Acceptance` as stated
  requirement contexts.
- Treat `Out of scope` and `Non-goals` headings as non-goal contexts.
- Treat modal or imperative language as explicit requirements.
- Treat assumption and implication language as inferred behavior to confirm.
- Surface missing format, acceptance, non-goal, input, output, or verification
  details through deterministic checks.

## Non-Goals

- No task decomposition.
- No worker dispatch.
- No review gating.
- No model-only inference that cannot be traced to source language.
