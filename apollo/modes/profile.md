---
name: Apollo profile mode
description: Guided on-device profiling conductor. Turns intake, scenario, signpost plan, capture, artifact export, attribution, recommendation, and post-fix verification into a strict-9 session workflow.
type: mode-pack
schema_version: 1
snapshots: []
budget_tokens: 5000
session_budget: 1800s
locks:
  - real-device-{udid}
  - xctrace-{device}
emits:
  - apollo_capture_started
  - apollo_capture_completed
  - apollo_capture_deferred
  - apollo_refused
reads:
  - apollo/_shared/primitives/source-map.md
  - apollo/_shared/primitives/scenarios.md
  - apollo/_shared/primitives/signpost-assistant.md
  - apollo/_shared/primitives/code-attribution.md
  - apollo/_shared/primitives/evidence-gate.md
  - apollo/_shared/primitives/execution-surface.md
  - ~/.dev-studio/.runtime/host-capabilities.yaml
  - ~/.dev-studio/<project>/apollo/scenarios/*.yaml
writes:
  - ~/.dev-studio/<project>/apollo/scenarios/<scenario-id>.yaml
  - ~/.dev-studio/<project>/apollo/signpost-plans/<plan-id>.yaml
  - ~/.dev-studio/<project>/apollo/captures/<id>/**
  - ~/.dev-studio/<project>/apollo/deferred/<id>.yaml
  - ~/.dev-studio/<project>/events/<today>.jsonl
---

# Mode: Profile (`/apollo profile`)

`/apollo profile` is the guided session conductor. It does not diagnose a metric by itself and it does not recommend from conversation. It turns a human-run or automated device workflow into the artifacts required by the metric modes (`memory`, `cpu`, `thermal`, `battery`, `network`), then hands analysis to the selected mode.

## Session phases

| Phase | Human-run responsibility | Automated / Apollo responsibility | Output |
|---|---|---|---|
| Intake | Name device, OS, build, app install source, suspected metric, and user flow | Normalize metric target; create or load scenario | Valid `apollo-scenario` artifact |
| Preflight | Pair/unlock real device; confirm Xcode/Instruments access; provide dSYM status | Check `host-capabilities.yaml`, source-map rows, and symbolication readiness | Preflight pass or blocker |
| Signpost plan | Approve instrumentation points or existing signposts | Generate `apollo-signpost-plan`; block if required signposts are absent | Patch-ready brief seed or capture-ready plan |
| Capture plan | Follow Xcode/Instruments/on-device Performance Trace steps | Select templates: CPU Profiler, Time Profiler, Power Profiler, Allocations, Network, System Trace, MetricKit/Organizer | Ordered capture checklist |
| Guided run | Start capture, perform scenario steps, stop/export artifacts | Record expected artifact paths and sidecars | `apollo/captures/<id>/` |
| Analysis handoff | Provide exported `.trace`, `.xcresult`, MetricKit, Organizer, or Performance Trace bundle | Dispatch to metric mode; validate strict-9 evidence; run code-area attribution | Recommendation, refusal, or advisory |
| Post-fix | Re-run matched scenario on same cohort | Compare axes from scenario + mode; refuse weak completion claims | Verification verdict |

## Capture sources

| Source | Use | Gate |
|---|---|---|
| Local Xcode-connected Instruments | Preferred for reproducible CPU, memory, thermal, battery, and network scenarios | Requires real-device pairing for power/thermal and target-cohort CPU; network power/radio claims require real device |
| `xctrace` automated run | Preferred when AXe/XCTest can drive the flow | Requires scenario + signpost interval |
| On-device Performance Trace | Human-run fallback when the issue occurs away from the Mac | Requires exported trace bundle, build, cohort, and dSYM/symbolication path |
| MetricKit / Organizer / ASC | Field-only or post-release confirmation | Requires payload window, cohort, build, and dSYM status |
| `URLSessionTaskMetrics` export | Deterministic network timing under a scenario test target | Requires task labels, signpost/window, cohort, build, and baseline |

## Blocker states

| Blocker | Response |
|---|---|
| Missing metric target | Ask once for one of `memory`, `cpu`, `thermal`, `battery`, `network`; do not guess |
| Missing scenario details | Write scenario draft and stop before capture |
| Required signpost absent | Emit signpost brief seed; block before capture or retry once after instrumentation |
| Host capability unavailable | Emit strict-9 refusal with `capability_unavailable`; allow `--evidence <path>` resume |
| dSYM / symbolication missing | Capture may be retained, but code-area attribution is blocked |
| Cohort mismatch | Re-capture or re-baseline; do not compare across device/OS/build axes |
| Network condition mismatch | Re-capture or narrow cohort; do not compare cellular poor-condition payloads to good-condition targets |
| Artifact exported but strict-9 fields missing | Refuse with exact missing fields and unblock recipe |

## Procedure

1. **READ** intake and resolve metric target.
   Before: user invokes `/apollo profile` with free text or flags.
   After: one or more metric targets are selected, or Apollo asks once and stops.

2. **WRITE** or validate the scenario.
   Before: user flow and cohort are known.
   After: `apollo/_shared/primitives/scenarios.md` contract is satisfied.

3. **CHECK** signposts.
   Before: scenario exists.
   After: required points of interest are present, or `apollo/_shared/primitives/signpost-assistant.md` emits a patch-ready brief seed.

4. **RUN** capture or guide the human-run capture.
   Before: host/device/capability preflight passes.
   After: artifact sidecar links scenario id/version, template, cohort, and compare axes.

5. **PROCEED** to the metric mode.
   Before: artifacts exist.
   After: selected mode evaluates strict-9 evidence and code-area attribution.

6. **CHECK** post-fix verification.
   Before: patch lands or user asks whether it is fixed.
   After: matched rerun verifies, partially verifies, regresses, or refuses the claim.

## Failure modes

| Failure | Classification | Response |
|---|---|---|
| Metric target missing after intake | permanent | Ask once for one of `memory`, `cpu`, `thermal`, `battery`, `network`; stop without capture |
| Scenario cannot be made valid | permanent | Write the invalid fields and required scenario schema; stop before capture |
| Required signpost absent | ambiguous | Emit a signpost assistant brief seed; retry once after instrumentation, then refuse with `reason: signpost_missing` |
| Host cannot capture and no evidence path was supplied | permanent | Emit strict-9 refusal with `reason: capability_unavailable` and `--evidence <path>` resume recipe |
| Real device unavailable for real-device-only metric | permanent | Refuse the capture; simulator is not a substitute for battery, thermal, or target-cohort CPU evidence |
| dSYM or symbolication missing | ambiguous | Keep the artifact but block code-area attribution until symbols resolve |
| Capture exceeds session budget | transient | Write `apollo/deferred/<id>.yaml` and report the deferred capture recipe |
| Post-fix rerun does not match scenario/cohort/template axes | permanent | Refuse the completion claim and require matched rerun |

## Non-goals

- Do not replace `memory`, `cpu`, `thermal`, or `battery`; profile orchestrates them.
- Do not replace `network`; profile captures or guides the network scenario, then hands analysis to network mode.
- Do not recommend fixes without artifacts.
- Do not require every scenario to be automatable.
- Do not embed SwiftUI, Imgly, or Metal domain internals; use code-area ownership routing.

## See also

- `apollo/_shared/primitives/scenarios.md`
- `apollo/_shared/primitives/signpost-assistant.md`
- `apollo/_shared/primitives/code-attribution.md`
- `apollo/_shared/primitives/evidence-gate.md`
- `apollo/modes/{memory,cpu,thermal,battery}.md`
- `apollo/modes/network.md`
