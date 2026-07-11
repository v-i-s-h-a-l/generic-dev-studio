---
name: SDL Task
about: A task routed through SDL governance
title: "[SDL] "
labels: sdl
---

## Goal

One-sentence description of the task.

## SDL classification

<!-- sdl-classification:start -->
schema_version: "sdl-classification@1"
intent_class: execution
capability: capability-client-orchestrator
role: client-project-orchestrator
allowed_paths:
  - src/
  - tests/
risk_tier: 2
chain_id: CHAIN_ID
depends_on: []
authority:
  approval_gate: user-instruction
  verification: "pytest tests/"
  rollback_plan: "git revert HEAD"
execution_policy:
  autonomy: approval-required
  token_budget: 4000
  hydration_budget: 1000
  gates:
    - ask
<!-- sdl-classification:end -->

## Notes

Add any additional context for the agent.
