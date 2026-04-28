---
name: Debrief Format
description: Active Achilles debrief contract. Debriefs are YAML artifacts under plans/debriefs/ and validate against debrief.schema.json.
type: reference
---

# Shared: Debrief Format

Active debrief producers write YAML to:

`~/.dev-studio/<project>/plans/debriefs/<debrief-id>.yaml`

The canonical schema is `_shared/contracts/debrief.schema.json`; the human
field guide is `_shared/schemas/debrief.md`.

Minimum active shape:

```yaml
schema_version:
  name: debrief
  version: 2.3.0
  min_reader: 2.0.0
  deprecated_at: null
id: <uuidv7>
task_id: <uuidv7-or-null>
brief_id: <uuidv7-or-null>
mode: task
state: emitted
completed_at: <rfc3339-utc>
branch:
  worked_on: achilles/<task-id>
  merged_into: <branch-or-null>
  merge_sha: <sha-or-null>
commits: []
diff_summary:
  files: 0
  added_lines: 0
  removed_lines: 0
decisions: []
tests:
  added: []
  modified: []
  skipped_because: null
testability: null
build_gate: lsp-only
build_debt_override: false
debt:
  build: false
  test_unit: false
  test_ui: false
  notes: null
performance: []
key_learnings: []
known_issues: []
follow_ups: []
open_questions: []
argus_review:
  status: not-invoked
  review_id: null
  notes: null
report_state: done
metrics: null
```

Task-mode writers normally call `scripts/task-emit-debrief.sh`, which wraps
`write_debrief_artifact` from `scripts/lib-ledger.sh`, validates the payload,
sets `tasks/<uuid>.yaml` `links.debrief`, and emits `debrief_emitted`.

The archived pre-Phase 2.6 section-header template lives at
`_shared/contracts/.legacy/debrief-format-md.md` for old artifact readability
only. Active writers MUST NOT use it.
