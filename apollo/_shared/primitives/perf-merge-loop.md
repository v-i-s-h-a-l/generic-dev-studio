---
name: Apollo perf-merge loop
description: The merge gate for perf-mode briefs. Apollo dispatches Achilles to apply the candidate fix on a worktree, then re-captures on the brief's cohort, then refuses or approves on observed-vs-baseline delta. Argus is skipped for these merges (see argus/SKILL.md skip predicate).
type: reference
schema_version: 1
---

# Perf-merge loop

Apollo is a router-plus-gate. Mode packs (`apollo/modes/{memory,thermal,battery}.md`) recommend candidate fixes; this primitive defines how those recommendations become merges.

The loop is the load-bearing answer to "what gates a perf-mode merge?" Argus is skipped for `dispatch_agent: apollo` briefs (see `argus/SKILL.md` skip-threshold §2). The strict-9 evidence gate (`apollo/_shared/primitives/evidence-gate.md`) is what's left.

## Pre-conditions

A brief written with `dispatch_agent: apollo` carries:

- `perf_mode: memory | thermal | battery | cpu` — selects the mode pack.
- `evidence.artifacts[]` — the captured baseline (`.trace`, `MXMetricPayload`, `.xcresult`, etc.).
- `evidence.baseline_ref` — the git ref the baseline was captured against.
- `evidence.capture_plan` — only when `artifacts` is empty; declares the auto-capture Apollo will run before the loop.

If both `artifacts` and `capture_plan` are missing, refuse at dispatch (strict-9). The brief is malformed; route back to Chanakya with the refusal block.

## Loop

```
┌──────────────────────────────────────────────┐
│ 1. ENTER mode pack (memory|thermal|battery|cpu)  │
│    — read brief, load evidence artifacts     │
│    — pick candidate fix per mode pack        │
└──────────────────────────────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────────┐
│ 2. DISPATCH Achilles to apply the fix on a   │
│    worktree branched from baseline_ref       │
│    — Achilles operates in standard task mode │
│    — Argus is skipped (Apollo-skip predicate)│
└──────────────────────────────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────────┐
│ 3. RE-CAPTURE on the SAME cohort that        │
│    produced the baseline                     │
│    — same device, same OS, same build config │
│    — cohort mismatch → REFUSE; loop returns  │
│      to step 2 with a re-capture directive   │
└──────────────────────────────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────────┐
│ 4. COMPUTE delta: observed - baseline        │
│    — direction: improved | regressed |       │
│      unchanged                               │
│    — pct + absolute, in measure's native     │
│      unit (MB, °C, mAh, ms, …)               │
└──────────────────────────────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────────┐
│ 5. VERDICT                                   │
│    — approved: delta.direction == improved   │
│      AND magnitude exceeds the mode pack's   │
│      noise floor                             │
│    — refused: regressed OR within noise OR   │
│      cohort mismatch                         │
│    — advisory: tier-1 anti-pattern only,     │
│      no measurement; never auto-merges       │
└──────────────────────────────────────────────┘
                    │
            approved ▼      refused ▶ back to 2
┌──────────────────────────────────────────────┐
│ 6. MERGE — Achilles' standard merge path     │
│    fires; Apollo emits the metrics-block     │
│    debrief (debrief@2.2.0+, metrics: { … })  │
└──────────────────────────────────────────────┘
```

## Cohort match

A re-capture is only valid when the device + OS + build config from `baseline.cohort` matches the observed cohort. iPhone 12 baseline vs. iPhone 16 Pro post-fix is **always** a refusal — different cohorts measure different things. The mode packs document per-metric cohort sensitivity (memory: device class matters most; thermal: OS version + chassis; battery: chassis + workload duration).

When the user only has one device available and the baseline was captured on a different one, the right move is **re-capture the baseline on the available cohort first**, then enter the loop. Apollo's `/apollo measure <metric> --capture-only` mode exists for exactly this preflight.

## Noise floor

Each mode pack declares a noise floor in its frontmatter (e.g., memory: ±5 MB or ±2% peak resident, whichever is larger). A "delta improved by 0.3 MB" with a 5 MB noise floor is **unchanged**, not improved — refuse with `reason: within-noise`. The user can re-dispatch with a tighter cohort or a larger workload, but Apollo will not approve a merge that may be measurement noise.

## Refusal shapes

All refusals populate `metrics.refusal` on the debrief (`debrief@2.2.0+`):

| Reason | When | Required action |
|---|---|---|
| `cohort-mismatch` | Step 3 cohort ≠ baseline cohort | Re-capture on the baseline cohort (or re-baseline on the new cohort) |
| `regressed` | Step 5 delta.direction == regressed | Revert; re-enter loop with a different candidate |
| `within-noise` | \|delta\| < noise floor | Tighter capture; longer workload; or accept that the candidate had no effect |
| `missing-evidence` | Pre-condition fail; no artifacts and no capture_plan | Brief is malformed; Chanakya re-authors |
| `advisory-only` | Tier-1 anti-pattern, no measurement | Advisory FLAG; never auto-merges |

The refusal block lists `reason` + `required_action`. Chanakya's debrief-ingest reads this and either marks the task `reopened` (for `regressed` / `within-noise` / `cohort-mismatch`) or flips it to `cancelled` (for `missing-evidence`).

## Why Argus is skipped

Apollo's strict-9 gate is **stricter** than Argus's spec-compliance + code-quality stages for perf-mode work:

- Spec-compliance asks "does diff match the brief?" — a perf brief's acceptance is a measurable delta on a cohort. Apollo's verdict is the answer.
- Code-quality asks "is this code good?" — for a perf merge, "good" means "moves the metric without regressing other metrics". The loop's per-mode-pack noise-floor + cross-metric checks (memory mode pack also re-checks thermal headroom, etc.) cover this.

Running both gates compounds latency without compounding signal. If a perf merge ships ugly-but-fast code, that's a tech-debt task for later; Argus running on the perf merge would block it on a style finding the evidence gate already ruled was acceptable.

## Cross-refs

- `apollo/_shared/primitives/evidence-gate.md` — the strict-9 contract (what counts as evidence).
- `apollo/_shared/primitives/execution-surface.md` — how Apollo orchestrates capture (XcodeBuildMCP / AXe / `xctrace`).
- `apollo/_shared/primitives/regression-detection.md` — delta-vs-noise math the loop's step 4–5 use.
- `argus/SKILL.md` — skip-threshold §2 documents the Apollo-skip predicate.
- `_shared/schemas/brief.md` — `dispatch_agent`, `perf_mode`, `evidence` fields.
- `_shared/schemas/debrief.md` — `metrics` block.
