---
name: Field Workflow Telemetry
description: Field workflow report metrics, privacy boundary, and improvement mining rules.
type: pattern
---

# Field Workflow Telemetry

`scripts/field-workflow-report.sh` reads canonical project events from
`~/.dev-studio/<project>/events/YYYY-MM-DD.jsonl` via `scripts/read-events.sh`
and joins best-effort brief metadata from `~/.dev-studio/<project>/plans/briefs`.
It is a private analysis surface first: it ranks bottlenecks and telemetry gaps
without publishing project-specific detail.

## Metrics

- Stage timing: explicit `duration_s` or paired start/end events for intake,
  brief authoring/review, dispatch wait, implementation before first gate,
  build/test gates, Argus review stages, debrief/sweep, user dwell, release
  handoff, and per-agent sessions.
- Token usage: `agent_session_completed` and reviewer token fields split by
  agent, mode, model, host, and task size. Missing token fields are counted as
  gaps, not zero.
- Build/test quality: pass/fail, first-try pass, retry pass, warning/error
  counts, node, gate mode, attempt, and abstract failure class.
- Review quality: Argus requested, approved, flagged, blocked, skipped, and
  infra-failed counts by review stage, with paired review latency where events
  exist.
- Brief quality: task size, summary presence, acceptance count, recommended
  model, and rework signals when brief YAML is available.

## Improvement Mining

The report prints improvement candidates only from aggregate thresholds:

- high gate failure or retry rate -> inspect the dominant failure class and file
  reliability work;
- high token cost on XS/S tasks -> improve brief slicing, model recommendation,
  or selective rule loading;
- high Argus skip/infra-failure rate -> file review-gate reliability work;
- visible build queue wait -> tune worker pool, node capacity, or priority;
- rework correlated with missing summary/acceptance -> tighten brief-quality
  lint;
- remote fallback -> inspect node health, source sync, and parity.

## Privacy Boundary

Safe for public issues: abstract rates, failure classes, missing telemetry
fields, and non-identifying workflow patterns.

Keep in private analysis only: task IDs, feedback IDs, feature names, file
paths, branch names, build numbers, release versions, exact private timings,
performance/velocity numbers, Slack channels, names, mentions, and verbatim
debrief or review text.
