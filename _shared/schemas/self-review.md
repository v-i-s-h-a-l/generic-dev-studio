---
name: Self-Review Schema
description: YAML shape for Achilles self-review artifacts under plans/self-reviews/<task-id>.yaml. Captures per-skill verdicts, diff stats, iteration count, and findings for Argus Stage 2 cross-checking.
type: reference
---

# Self-Review Schema (`self-review@1.2.0`)

Per-task artifact written to `~/.dev-studio/<project>/plans/self-reviews/<task-id>.yaml` at Step 5 completion. Read by Argus Stage 2 to cross-check skill verdicts and coverage gates without re-deriving from debrief prose.

## Shape

```yaml
schema_version:
  name: self-review
  version: 1.2.0
  min_reader: 1.0.0
task_id: T123
completed_at: 2026-04-27T12:00:00Z
iteration: 1           # 1 = no fix-rerun; 2 = one fix-rerun occurred (cap)
converged: true        # false if iteration cap hit with material findings still present
self_review_performed: true
self_review_findings:
  - id: SR1
    focus: edge_case
    finding: "Empty input path was not covered by the first implementation."
    severity: material
    disposition: fixed
self_review_fixes:
  - finding_id: SR1
    action: fixed
    summary: "Added the empty-input guard before final verification."
skill_verdicts:        # keyed by skill name; value: clean | minor | material
  simplify: clean
  swiftui-pro: minor
  swift-concurrency-pro: clean
diff_stats:
  files: 4
  added_lines: 187
  removed_lines: 12
  public_api_changed: false  # true if any public/open/protocol conformance changed
findings:
  - skill: swiftui-pro
    severity: minor    # minor | material
    text: "Used unnecessary @State for non-mutating value"
    fixed: true        # false if iteration cap hit before fix landed
refactoring_pressure:
  needed_now:
    - kind: localized_cleanup
      reason: "Duplicated parsing would make the touched change unsafe to maintain."
      affected_area: "FilterPresetParser"
      risk: low
      implemented_change: "Extracted parsePresetName(_:) before adding the new branch."
  deferred_follow_ups:
    - kind: duplication
      reason: "Third similar branch added across adjacent exporters."
      affected_area: "ExportPresetMapper"
      risk: medium
      suggested_timing: "After this bounded task; not required for correctness."
coverage_delta_checked: true   # false for bug-type and test-only tasks
coverage_delta_found: true     # true if ≥1 test file changed or added
```

## Written by

`scripts/task-write-self-review.sh <task-id> '<fields-json>'` at Step 5 end.

## Read by

Argus Stage 2 (`argus/modes/review.md`): reads `skill_verdicts` and `findings` via `yq` to cross-check without re-parsing debrief prose. A missing file is treated as "no prior self-review" (backward-compatible with tasks predating this schema).

## Interaction with external reviews

Self-review is not a substitute for structured reviewer findings. When same-host self-review overlaps with external review (#605), the worker still records external reviewer finding dispositions in `contracts/worker-report.md` / `schemas/debrief.md`. Use self-review to expose local skill verdicts; use review verdict metadata (#537 context scope, #604 test/runtime evidence, #606 finding rubric) to decide whether to fix, modify, reject, escalate, or defer external findings.

The same-host self-review gate runs before final verification. External reviewers inspect `self_review_performed`, `self_review_findings`, `self_review_fixes`, and final verification evidence before requesting independent reruns. Missing self-review is a warn or block workflow defect in the reviewer verdict.

## Refactoring pressure

Worker self-review scans for code bloat, duplication, SOLID/design pressure, awkward module boundaries, and localized cleanup opportunities. It records the split in `refactoring_pressure`:

- `needed_now[]`: refactors performed because the current change would otherwise be incorrect, unsafe to maintain, or impossible to complete cleanly.
- `deferred_follow_ups[]`: real design debt that is outside the bounded task. Each item carries `kind`, `reason`, `affected_area`, `risk`, and `suggested_timing` so the debrief can copy it into `follow_ups[]` for manager ingestion.

Workers do not perform broad cleanup just because self-review found pressure. Broad refactoring belongs in explicit follow-up work unless it is required for the current change.
