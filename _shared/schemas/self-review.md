---
name: Self-Review Schema
description: YAML shape for Achilles self-review artifacts under plans/self-reviews/<task-id>.yaml. Captures per-skill verdicts, diff stats, iteration count, and findings for Argus Stage 2 cross-checking.
type: reference
---

# Self-Review Schema (`self-review@1.0.0`)

Per-task artifact written to `~/.dev-studio/<project>/plans/self-reviews/<task-id>.yaml` at Step 5 completion. Read by Argus Stage 2 to cross-check skill verdicts and coverage gates without re-deriving from debrief prose.

## Shape

```yaml
schema_version:
  name: self-review
  version: 1.0.0
  min_reader: 1.0.0
task_id: T123
completed_at: 2026-04-27T12:00:00Z
iteration: 1           # 1 = no fix-rerun; 2 = one fix-rerun occurred (cap)
converged: true        # false if iteration cap hit with material findings still present
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
coverage_delta_checked: true   # false for bug-type and test-only tasks
coverage_delta_found: true     # true if ≥1 test file changed or added
```

## Written by

`scripts/task-write-self-review.sh <task-id> '<fields-json>'` at Step 5 end.

## Read by

Argus Stage 2 (`argus/modes/review.md`): reads `skill_verdicts` and `findings` via `yq` to cross-check without re-parsing debrief prose. A missing file is treated as "no prior self-review" (backward-compatible with tasks predating this schema).
