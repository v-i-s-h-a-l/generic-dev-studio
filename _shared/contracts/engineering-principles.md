---
name: Engineering Principles Contract
description: Shared quality bar for manager shaping, worker execution, and reviewer evaluation.
type: contract
---

# Engineering Principles Contract

Studio roles treat user prompts, generated plans, and prior artifacts as inputs
to sharpen, not as infallible instructions.

## Core Principles

- Prefer root-cause fixes over local bandages.
- Identify the broader failure mode before editing when the requested solution
  appears brittle, local-only, or likely to recur.
- Convert vague work into measurable acceptance criteria before dispatch or
  implementation.
- Split L-sized implementation work into S or M leaf tasks unless splitting
  would make the work less safe or less reviewable.
- Treat verification as part of implementation. Skipped tests, builds, or lints
  need an explicit reason and residual risk.
- Surface tradeoffs when the simplest implementation risks scale,
  maintainability, future feature work, or long-lived ownership.
- Design for production systems that grow: clear boundaries, durable naming,
  explicit ownership, and reviewable behavior changes.
- Auto-propose stronger approaches when engineering evidence supports them, but
  require user approval for scope, behavior, permission, release, or ask-first
  policy changes.

## Manager Application

Manager-shaped work includes:

- Goal and user impact.
- In-scope changes and non-goals.
- Measurable, reviewer-testable acceptance criteria.
- Churn layer, task size, risk level, and recommended verification.
- Challenge/refine notes when the initial request is vague, brittle, oversized,
  or missing verification.

## Worker Application

Worker execution includes:

- Root-cause notes for bug fixes and non-trivial changes.
- A same-host self-review before final verification.
- Final verification evidence appropriate to task size, risk, and churn layer.
- Explicit blocked or skipped-check reasons when verification cannot run.

## Reviewer Application

Reviewer verdicts can evaluate against this contract without the full
conversation by reading the shaped plan, worker summary, diff, and verification
evidence. Findings distinguish:

- Missing root-cause analysis.
- Unmeasurable acceptance criteria.
- Oversized work that should have been split.
- Verification that is absent, stale, too narrow, or not tied to the diff.
- Scope expansion that crosses ask-first boundaries without approval.

## Verification Matrix

| Size / risk | Minimum expectation |
|---|---|
| XS docs or metadata | Focused lint, schema, grep, or fixture check; explain if no executable check exists. |
| S low-risk code | Focused unit, contract, script, or lint check that reaches the changed surface. |
| M or shared behavior | Focused tests plus relevant contract/schema/lint checks; include self-review notes. |
| Bug fix | Root-cause note plus reproducer, regression test, or explicit reason a reproducer is unavailable. |
| High-risk or cross-role substrate | Plan review, outcome review, focused verification, and PR review before merge. |

This contract complements `_shared/rules/test-strategy.md`: churn layer chooses
the test type, while size and risk choose the evidence floor.
