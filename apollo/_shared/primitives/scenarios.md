---
name: Apollo scenarios
description: Reusable scenario artifact contract for Apollo captures. Records user flow, cohort, preconditions, signposts, metric targets, expected artifacts, and compare axes for repeatable performance analysis.
type: reference
schema_version: 1
---

# Apollo scenarios

Apollo scenarios turn a user flow into a repeatable artifact. The runtime path is:

```text
~/.dev-studio/<project>/apollo/scenarios/<scenario-id>.yaml
```

The schema is `_shared/contracts/apollo-scenario.schema.json`. Validate with:

```bash
scripts/validate-contract.sh apollo-scenario <scenario.yaml>
```

## Required fields

| Field | Purpose |
|---|---|
| `scenario_id` + `scenario_version` | Stable identity and version. Any flow, precondition, signpost, duration, or compare-axis change increments `scenario_version`. |
| `app` | Names the app install/build source so Debug, Release, TestFlight, and App Store data do not mix silently. |
| `cohort` | Pins device, OS, and target kind. Cross-cohort comparison fails the strict-9 gate unless explicitly downgraded to advisory. |
| `preconditions` | Records conditions that perturb performance: login, network, charging, thermal state, brightness, and Low Power Mode. |
| `flow` | Ordered human-readable steps. Steps do not require automation; human-run Xcode/device sessions are valid. |
| `signposts` | Points of interest Apollo expects in the artifact. Required signposts missing from local traces fail with `reason: signpost_missing`. |
| `metric_targets` | One or more of `memory`, `cpu`, `thermal`, `battery`. Mode packs read only their target rows but preserve the full scenario. |
| `capture` | Names whether the run is `human-run`, `automated`, or `hybrid`, the duration/dwell, and the tool family. |
| `expected_artifacts` | Names the artifact types Apollo should collect or ask the user to supply. |
| `compare_axes` | The axes that must match between baseline, observed, and post-fix captures. |

## Artifact sidecar link

Every capture sidecar that used a scenario records the scenario identity:

```yaml
scenario:
  path: ~/.dev-studio/<project>/apollo/scenarios/feed-scroll-cpu.yaml
  id: feed-scroll-cpu
  version: 1
  compare_axes: [scenario_id, scenario_version, cohort, build_configuration, signpost, duration_s, template]
```

The sidecar link is mandatory when a mode was invoked with `--scenario <id-or-path>`. Apollo refuses post-fix verification if the pre-fix and post-fix sidecars name different `scenario_id`, `scenario_version`, or mode-specific compare axes.

## Human-run flow

Human-run scenarios are first-class. Apollo may guide the user through Xcode and Instruments, but the scenario remains the source of truth:

1. **READ** the scenario and validate it.
   Before: user invokes `/apollo <mode> --scenario <id-or-path>` or supplies a scenario path.
   After: mode, cohort, preconditions, flow, signposts, expected artifacts, and compare axes are known.

2. **CHECK** host capabilities.
   Before: capture mode and tools are known.
   After: Apollo either drives available automation or emits a human-run checklist with the same scenario fields.

3. **RECORD** the completed artifact sidecar.
   Before: artifact exists under `apollo/captures/<id>/`.
   After: sidecar links to the scenario path, id, version, and compare axes.

## See also

- `_shared/contracts/apollo-scenario.schema.json`
- `apollo/_shared/primitives/signposts.md`
- `apollo/_shared/primitives/signpost-assistant.md`
- `apollo/_shared/primitives/regression-detection.md`
- `apollo/_shared/primitives/evidence-gate.md`
- `apollo/modes/measure.md`
