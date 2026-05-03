---
name: Build Debt Schema
description: Counter rules, state transitions, and YAML schema for the per-project build-debt counter that governs TBUILD threshold actions.
type: reference
---

# Shared: Build Debt Schema

The build-debt counter governs when the manager mints a TBUILD verification task (warn threshold) or sets the project-wide block flag (block threshold). Pre-#273 the counter lived only inside `plans/chanakya-master.md`. Post-#273 it lives at `plans/build-debt.yaml` as the canonical source; the `## Build Debt` section in `chanakya-master.md` is a render projection produced by `scripts/render-master-plan.sh`.

The manager owns all writes; workers only read.

## Path

`~/.dev-studio/<project>/plans/build-debt.yaml`

One file per project. Created on demand by `scripts/extract-master-plan-preamble.sh` (one-shot bootstrap from existing master-plan) or by the first build-debt mutation through `lib-ledger.sh` if absent.

## Shape

```yaml
schema_version: {name: build-debt, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
counter: 8                      # integer ≥ 0
state: warn                     # silent | warn | block
warn_at: 6                      # integer; threshold for build_debt_warned event
block_at: 12                    # integer; threshold for build_debt_blocked event
last_green: "build-20260414-093200 (2026-04-14 09:32)"   # free text or null
last_green_sha: "a1b2c3d"       # 7+ char SHA or null
unverified_since: ["T015", "T016", "T017"]               # list of legacy task ids; may carry "[overridden]" suffix
broken_commit_sha: null         # populated only when state=block from a red build
open_check_task: "TBUILD-3"     # legacy task id or null when no open TBUILD
blocked_by: null                # legacy task id (P0 fix task) or null
next_tbuild_n: 4                # next allocation for TBUILD-N legacy id
notes: null                     # optional free text appended below the projected section
updated_at: 2026-04-27T08:13:00Z
```

## Field semantics

| Field | Read by | Written by |
|---|---|---|
| `counter` | `sweep-threshold-actions.sh`, `render-master-plan.sh`, `task-build-debt-gate.sh` | `sweep-ingest.sh` (red → +1), green-build path (→ 0), `lib-ledger.sh::build_debt_increment` / `build_debt_reset` |
| `state` | render projector, threshold script | sweep-ingest, threshold script (transitions to `warn` / `block`) |
| `warn_at` / `block_at` | threshold script, projector | hand-edited (rare); rule defaults below |
| `last_green` / `last_green_sha` | projector | sweep-ingest on green build-check |
| `unverified_since` | projector, gate banner | sweep-ingest on lsp-only debrief or red build-check |
| `broken_commit_sha` | projector | sweep-ingest on red build-check; cleared on next green |
| `open_check_task` | projector, threshold script | threshold script when minting TBUILD; cleared by sweep when task verified |
| `blocked_by` | projector, gate | sweep-ingest red path; cleared on next green |
| `next_tbuild_n` | sweep-ingest red path, threshold script | both, atomically incremented on TBUILD allocation |

## Counter Update Rules (applied by Chanakya per debrief)

| Debrief `build_gate` | Debrief `build_debt_override` | Action |
|---|---|---|
| `full-green` | false | `counter` → 0; `state` → `silent`; update `last_green`; clear `unverified_since`; close `open_check_task`. |
| `lsp-only` | false | `counter` += 1; append task-id to `unverified_since`. |
| `lsp-only` | true | `counter` += 1; append `<task-id>[overridden]` to `unverified_since`. |
| `full-green` | true | `counter` → 0; override flag irrelevant (real full-green clears debt regardless). |

## State Transitions

- `counter = 0` → `state: silent`
- `counter ∈ [1, warn_at-1]` → `state: silent`
- `counter ∈ [warn_at, block_at-1]` → `state: warn`. File TBUILD on the (warn_at-1)→warn_at transition.
- `counter ≥ block_at` → `state: block`
- `blocked_by: T<nnn>` outstanding → `state: block` regardless of counter.

Default thresholds: `warn_at: 6`, `block_at: 12`. Override per-project by hand-editing the YAML.

## Worker: Build Debt Gate

Read `plans/build-debt.yaml` (or fall back to the projected `## Build Debt` block in master-plan if YAML absent — pre-#273 projects) before starting any task:

- **`counter ≤ warn_at-1`:** proceed silently.
- **`counter ∈ [warn_at, block_at-1]` (warn):** print one-line banner, proceed.
  > "⚠️ Build debt: 8 tasks merged without a full build. Run `/dev-studio worker build` when convenient. (Block at 12 — 4 more until new work refused.)"
- **`counter ≥ block_at` (block):**
  - If task has `source: build-debt` in its task YAML (it's a TBUILD): proceed — exempt.
  - If `--ignore-build-debt` passed: print override banner and proceed. Record `build_debt_override: true` in debrief.
  - Otherwise: print block banner and exit without claiming.
    > "⛔ Build debt blocked at 12. Run `/dev-studio worker build` before starting new work. Override (not recommended): `/dev-studio worker <task-id> --ignore-build-debt`."

Never write to `plans/build-debt.yaml` from the gate — read-only.

## Mutation contract

All mutations route through `lib-ledger.sh` helpers (`build_debt_read`, `build_debt_get`, `build_debt_set`, `build_debt_increment`, `build_debt_reset`, `build_debt_annotate_red`). Helpers update `updated_at` automatically. Direct `yq -i` edits forbidden — caught by code review per `REVIEW.md` R9 (mutation-via-helper invariant).

The `## Build Debt` section in `chanakya-master.md` is a **render projection** post-#273 — never hand-edit. Edits to the YAML take effect on the next `render-master-plan.sh` run (which `sweep-ingest.sh` invokes at end-of-run).

## Bootstrap

Projects pre-dating #273 get their YAML created from the existing `chanakya-master.md` via `scripts/extract-master-plan-preamble.sh` (idempotent — no-op if YAML already present). The extractor parses the `## Build Debt` block and writes the YAML in one shot.

`sweep-threshold-actions.sh` reads the YAML first; if absent on a project, the read silently falls back to parsing `chanakya-master.md` (R-fallback per `audits/245-A1-reader-audit.md`) and emits `legacy_artifact_read{domain:build_debt, reason:no_build_debt_yaml}`. Both paths return the same integer counter. Post-A.4 (legacy archive), the fallback branch becomes unreachable for new projects and is deleted in A.5.
