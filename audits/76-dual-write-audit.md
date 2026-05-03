# Issue #76 Dual-Write Audit

Date: 2026-05-02
Scope: mode packs named in issue #76 plus active ledger writer scripts.

## Current Rule

The Phase 2.6 dual-write window is closed. Post-#245 A.4/A.5, Phase 2.6 artifacts write only canonical YAML through `scripts/lib-ledger.sh` writers and transition helpers. Retired `legacy_*` helpers fail loud with exit 9.

`_shared/patterns/dual-write-transition.md` remains as a reusable pattern for future migrations, not as an active write contract.

## Mode-Pack Classification

| Surface | Classification | Evidence |
|---|---|---|
| `chanakya/modes/intake.md` | yaml-only writer | Calls `write_task_artifact`; no legacy write target. |
| `chanakya/modes/brief.md` | yaml-only writer | Calls `write_brief_artifact`, `set_task_link`, and `transition_task_state`; explicitly forbids hand-edited YAML. |
| `chanakya/modes/feedback.md` | no Phase 2.6 legacy-only writer | Mutates task/feedback YAML; feedback markdown paths are the separate F-id feedback surface. |
| `chanakya/modes/sweep-debt.md` | no artifact write | `writes: []`. |
| `chanakya/modes/inbox-sweep.md` | yaml-only delegated writer | Delegates to `sweep-enumerate-debriefs.sh` and `sweep-ingest.sh`; legacy markdown is diagnostic-only. |
| `chanakya/modes/ship.md` | no Phase 2.6 artifact write | Writes only the worker queue. |
| `chanakya/modes/status.md` | no Phase 2.6 artifact write | Reads canonical YAML and writes only push-queue display state. |
| `chanakya/modes/verify.md` | no direct artifact write | Orchestrates tests/feedback/intake sub-modes. |
| `chanakya/modes/sync-slack.md` | no Phase 2.6 artifact write | Reads YAML, writes Slack list plus feedback reminder markdown. |
| `chanakya/modes/tests.md` | yaml-only writer | Round writes go through `scripts/tests-write-round.sh` -> `write_round_artifact`; historical test sidecars are read-only fallback. |
| `chanakya/modes/update.md` | yaml-only writer | Task state transitions via `lib-ledger`. |
| `chanakya/modes/compact.md` | yaml-only for Phase 2.6 artifacts | Task/feedback/round state transitions via YAML; archive/changelog markdown are retained editorial surfaces. |
| `chanakya/modes/review.md` | yaml-only writer | Mutates and mints tasks/briefs via lib-ledger-shaped steps. |
| `achilles/modes/task.md` | yaml-only writer | Debrief/task/brief mutations flow through task scripts backed by `lib-ledger`. |
| `achilles/modes/group.md` | no direct artifact write | Delegates to task mode. |
| `achilles/modes/app-store.md` | yaml-only writer | Writes release/debrief YAML and task release back-refs. |
| `achilles/modes/build.md` | yaml-only writer | Writes build-check debrief YAML; build debt markdown is rendered projection. |
| `achilles/modes/next.md` | no direct artifact write | Delegates to task mode. |
| `achilles/modes/push-tf.md` | yaml-only writer | Writes release/debrief YAML and task release back-refs. |
| `achilles/modes/test-suite.md` | yaml-only writer | Writes test-suite debrief YAML. |
| `argus/SKILL.md` | router, no artifact write | Actual review artifact writer is `scripts/argus-emit-verdict.sh`. |

## Script Audit

Active artifact producers route through these YAML writers:

- `write_task_artifact`
- `write_brief_artifact`
- `write_debrief_artifact`
- `write_review_artifact`
- `write_round_artifact`
- `write_release_artifact`
- `transition_task_state`
- `transition_brief_state`
- `transition_release_state`
- `transition_review_state`
- `transition_round_state`

The following stale dual-write references were removed in this audit because `lib-ledger.sh` no longer emits dual-write partial exit code 3:

- `scripts/argus-emit-verdict.sh`
- `scripts/task-claim.sh`
- `scripts/task-emit-debrief.sh`
- `scripts/task-finalize-merge.sh`
- `scripts/tests-write-round.sh`
- `scripts/sweep-ingest.sh`

## Grep Checks

Run from repo root:

```sh
rg -n 'legacy_(master_plan|inbox|brief|review|round|release).*\(' \
  scripts chanakya/modes achilles/modes argus \
  -g '*.sh' -g '*.md'

rg -n 'chanakya-inbox.*-debrief\.(md|yaml)|plans/chanakya-tasks|plans/chanakya-master\.md' \
  chanakya/modes achilles/modes argus scripts \
  -g '*.md' -g '*.sh'
```

Expected result: no active legacy-only Phase 2.6 writer. Allowed hits are migration/archive/diagnostic readers, rendered-projection readers, or retired helper definitions in `lib-ledger.sh`.

## Conclusion

No listed mode pack is a legacy-only Phase 2.6 writer. The remaining legacy reads are explicitly diagnostic, migration, or rendered-projection paths. The stale rc=3 dual-write prose in active scripts was the only live drift found.
