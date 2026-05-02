---
name: Build and Test Gate
description: Single-source-of-truth rule for build- and test-toolchain entry. All such calls in agent code route through the gate scripts (task-build-gate, task-test-gate, swift-test-gate).
type: reference
schema_version: 1
---

# Build / test gate (toolchain entry rule)

Every `xcodebuild`, `swift build`, and `swift test` invocation in agent code or mode prose routes through one of three gate scripts. Direct toolchain invocation from agent paths is the bug, not the queueing.

| Caller | Gate | Action |
|---|---|---|
| Achilles task mode Step 6 (XS/S) | `scripts/task-build-gate.sh lsp-only` | swift-lsp diagnostics; no xcodebuild |
| Achilles task mode Step 6 (M+ build) | `scripts/task-build-gate.sh full-green` | `xcodebuild build` under per-node lock |
| Achilles task mode Step 6 (package-only fast path) | `scripts/swift-test-gate.sh` | `swift test --package-path` |
| Achilles build mode | `scripts/task-build-gate.sh full-green` | same as task mode, `<task-id>` = `<build-id>` |
| Achilles test-suite mode | `scripts/task-test-gate.sh` | `xcodebuild test` under per-node lock |
| Argus M/L review test phase | `scripts/argus-run-tests.sh` | machine-local test-slot semaphore (intentional carve-out — runs against `Argus-N` simulators that are per-machine) |

The gates own three responsibilities: node-pick (route to a healthy worker tagged for the role, fall back to local), lock acquisition (per-node `xcodebuild-lock/<node-id>/slot-<n>/` with 45-min staleness reclaim, fed by a per-node priority queue at `build-queue/<node-id>/` so release builds move ahead of queued task/background work without stopping in-flight holders), and event emission (`build_check_*` for build, `build_queue_position` on enqueue, `build_queue_promoted` on release promotion, `test_run_*` for test). Skipping the gate skips all three.

For Swift package fast paths, the gate chooses the canonical package entry point before invoking `swift test`. If the nearest changed package is nested but the worktree root `Package.swift` references that package by local path, the gate runs `swift test --package-path .` from the worktree root so sibling local dependencies resolve through the same graph used by the project. Otherwise it runs against the nearest package root. Structural package failures are reported as `focused_verification_structurally_blocked` and the caller falls back to the canonical project build/test gate when broader verification is authorized.

Slot count comes from the node's `parallel_build_slots` field in `~/.dev-studio/.runtime/nodes.json` (default 1). At slots=1 the queue grants a single concurrent holder on `slot-1` — bit-identical to the pre-#268 single-dir lock. At slots>N the queue grants up to N concurrent holders, each pinned to a distinct `slot-<n>` subdir; build and test gates share the slot pool so a test pins one slot while builds use the rest. Bump `parallel_build_slots: 2+` on a node with capacity for parallel builds (#218 Stage C / #268).

## Why a single chokepoint

Pre-#215, mode prose instructed agents to "run xcodebuild …" inline — fine in single-machine setups, broken once a worker fleet existed. Build-debt counters fell out of sync because some builds emitted events and some didn't; concurrent achilles tasks all serialized on whichever machine the agent picked; a task-mode build could deadlock against a build-mode build because they used the same lock keyed by directory rather than by node. The gate's signature (mode + task-id + worktree + scheme + destination) is the same on every node — agent prose names the gate, the gate names the toolchain.

## Canonical-reference machine

**`m1mini` is the canonical-reference machine.** It carries the `snapshot-canonical` role tag in `~/.dev-studio/.runtime/nodes.json` and is the only machine that *generates* snapshot test reference images. Why mini and not the laptop:

- Fixed Xcode version (no IDE updates without explicit migration).
- Fixed simulator state (no beta runtimes, no per-feature stuck devices).
- Not used interactively, so the build environment doesn't drift between snapshot-generation runs.

The laptop (and any future worker) carries `swift-test` + `xcodebuild` roles only; it can run snapshot *assertions* (after pulling references via `scripts/snapshot-sync.sh`) but never *generates* references. `snapshot-sync.sh` resolves the canonical node by role, not by id — re-tagging is the ladder for switching reference machines, not edit-the-script.

## Self-node identity

A registered node entry whose `machine_id` matches the running machine's `machine_id` is *self*. The gates short-circuit SSH for self-nodes (run inline) but keep the lock keyed by the registered id — so a laptop-local build and a mini-dispatched build serialize on different locks and run in parallel, while two laptop-local builds queue on `xcodebuild-lock/laptop/slot-*/`. Helpers live in `scripts/lib-paths.sh`: `resolve_self_machine_id`, `node_machine_id_for`, `node_is_self`.

## Lint enforcement

`scripts/lint-build-invocations.sh` (run via the pre-commit pipeline) refuses raw `xcodebuild` / `swift build` / `swift test` calls in `achilles/`, `argus/`, `_shared/`, `scripts/`, and mode-pack files. The gate scripts themselves and `xcodebuild-shim.sh` are allow-listed. A genuinely unavoidable case (debugging tools, etc.) opts out with `# lint-build:allow next-line` plus a one-line rationale.

## Out of scope today

- `xcodebuild archive` (TestFlight / App Store builds) — moves to a studio-owned `studio-tf-push` wrapper in the release substrate arc; tracked separately.
- Argus M/L test runs — keep the machine-local test-slot semaphore for now; cross-node argus dispatch is a larger redesign.
- Priority queueing (TF / App Store builds preempting other workers) — separate issue.
