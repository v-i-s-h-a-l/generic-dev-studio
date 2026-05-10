---
name: 2026-05-10-artifact-cleanup-audit
description: Public summary of the studio shell-script artifact-producing call site audit at baseline SHA cdbc6e9 (chain artifact-cleanup-audit, issue #846 / T-R001). Documents offender taxonomy, per-workflow-surface counts, and explicit handoff cases.
type: audit
---

# Artifact Cleanup Audit — Studio Scripts (Public Summary)

**Baseline commit SHA:** `cdbc6e9`
**Audit date:** 2026-05-10
**Issue:** #846 (chain `artifact-cleanup-audit`, task graph node `T-R001`)

This is the public, abstracted summary of an audit of artifact-producing call
sites across the studio's shell-script corpus. The detailed file:line inventory
lives in a private working file under `~/.dev-studio/<project>/analysis/`; this
public summary intentionally omits any project-private context and reports
counts and verdicts only.

## Scope

**Audit corpus (globs):**

- `scripts/**/*.sh`
- `core/**/*.sh` — empty at baseline
- `hooks/*` — no artifact-producing call sites at baseline

`_shared/**` had no `.sh` files at baseline and was excluded.

## Offender criteria

A call site is an **offender** if it creates filesystem state in one of the
artifact classes below AND does not:

- (a) install an `EXIT`/`INT`/`TERM` trap that finalizes that state, or
- (b) opt in to one of the existing janitors (per-platform iOS-artifact janitor,
  node janitor, fleet cleanup, sweep janitor), or
- (c) hand off ownership to a downstream task that finalizes it.

### Verdict taxonomy

- `clean` — trap-cleaned on EXIT/INT/TERM (and/or RETURN), full coverage.
- `clean-on-success-only` — explicit `rm` after use, but no trap; signals or
  early-returns between create and rm leak.
- `leaks-always` — no cleanup of any kind on any path.
- `janitor-but-not-scheduled` — cleanup relies on a janitor whose schedule or
  opt-in is not visible from the call site itself.
- `handoff` — ownership documented to pass to a downstream worker/task.
- `rename-consumed` — not an offender; mktemp in atomic-write
  (`tmp=$(mktemp ...) ... mv "$tmp" "$target"`) pattern.

### Artifact classes scanned

1. xcodebuild DerivedData (default + custom `-derivedDataPath`).
2. `git worktree add` targets.
3. Per-project ephemeral runtime scratch (chain task envelopes, worker
   summaries not promoted to durable state, perf traces, qa/flow recordings,
   planner artifacts).
4. `/tmp` and `mktemp -d` directories.
5. Simulator devices booted via `xcrun simctl boot`.
6. `.xcresult` bundles, `.xcarchive` archives, `.ipa` files.

## Per-workflow-surface counts

Counts below are call sites, not files. Sub-issue mapping aligns with the
planned cluster slices for this arc.

| Workflow surface (planned sub-issue) | clean | clean-on-success-only | leaks-always | janitor-but-not-scheduled | handoff |
|---|---:|---:|---:|---:|---:|
| chain-runner + worker (T-R002) | ~12 | 18 | 13 | 6 | 4 |
| perf / review wrapper (T-R003) | 6 | 1 | 0 | 2 | 1 |
| qa + flow (T-R004 cluster) | 0 | 0 | 0 | 0 | 0 |
| release / TestFlight (T-R005) | 0 | 0 | 4 | 1 | 0 |
| structural primitive (T-R006) | 19 | 6 | ~30 | 0 | 0 |

Totals (production scripts): ≈37 clean, ≈25 clean-on-success-only, ≈47
leaks-always, ≈9 janitor-but-not-scheduled, ≈5 documented handoffs. Test
fixtures (~80 scripts) all use the canonical `TMPROOT + trap rm -rf`
pattern and contribute zero offenders.

## Headline findings

- **Long-tail of untrapped `mktemp`.** The single largest class of offenders is
  short-lived `mktemp` files used for one-shot JSON or row buffers in long-lived
  control-plane scripts. They are individually small but compound under signal
  paths and SIGINT exits. ~47 leaks-always sites in production scripts.
- **Archive class has a high-blast-radius leak.** The release/TestFlight
  workflow produces a multi-GB `.xcarchive` per push and never removes it.
  Single highest-priority offender by bytes-leaked-per-run.
- **Simulator state is not finalized.** Simulator boots in the perf/review
  surface have no corresponding shutdown. Long-running workers accumulate
  simulator state until host reboot or manual `simctl shutdown all`.
- **xcresult retention is correct but fragile.** The result-bundle on the
  perf/review path is documented as a downstream consumer's concern; the
  consumer does remove it, but worker death between produce and consume leaks.
- **DerivedData is janitor-managed but unscheduled at the call site.**
  `-derivedDataPath` is set via env in five chain-runner+worker call sites; the
  iOS-artifact janitor handles cleanup, but the dependency on the janitor being
  invoked is implicit at the call site (no annotation, no fail-closed path).
- **Test fixtures are exemplary.** Every test fixture follows
  `TMPROOT=$(mktemp -d -t ...) ; trap 'rm -rf "$TMPROOT"' EXIT`. This is the
  pattern that production-script offenders should converge on.

## Handoff cases (legitimate cross-task retention)

These call sites intentionally outlive their producer; downstream owners take
finalization responsibility. They are not offenders.

- **Chain worktrees.** Created by the chain-runner / per-task worktree setup;
  cleaned by the chain runner's PR-merge / cleanup phase per the chain task
  envelope contract.
- **Per-chain planner outputs.** Planner JSON and review markdown live under
  the per-project `plan-chains/<id>/` runtime root for the duration of the
  chain; chain runner owns retention TTL.
- **Per-task xcresult on the perf/review path.** Producer documents the bundle
  as the downstream verdict-emitter's concern.
- **Private chain-runner control artifacts.** `.studio/chain-task-start.json`
  and `.studio/chain-worker-summary.json` are envelope-private to the parent
  runner per the chain task contract; workers never delete them.

## Mapping to planned sub-issues

- **T-R002 (chain-runner + worker cleanup).** ~37 sites across chain-runner
  control plane, task gates (build/test/swift-test), and worktree setup.
  Highest-density surface; mix of clean-on-success-only and leaks-always.
  Includes the simulator-boot site if perf/review work is bundled.
- **T-R003 (perf / review wrapper cleanup).** ~10 sites; mostly already trap-
  cleaned. Remaining gaps are the xcresult handoff (worker-death edge), the
  simulator-boot finalize, and DerivedData annotation.
- **T-R004 (qa + flow cleanup).** No artifact-producing production scripts at
  baseline; qa-engineer and flow-tester surfaces exist only as role contracts
  and test fixtures. Sub-issue is preventative — establish the cleanup contract
  before runtime scripts land.
- **T-R005 (release / TestFlight cleanup).** Small site count (≈5) but the
  largest blast radius. The `.xcarchive` leak is the single most expensive
  offender.
- **T-R006 (structural primitive).** Library-level `mktemp` users
  (`lib-chain-monitor-*`, `lib-chain-run-state`, `lib-stepwise`,
  `lib-fixtures`, etc.) where the right fix is a shared
  `mktemp_traced` / `register_for_cleanup` helper, not per-site traps.

## Recommendations

1. Land the lint allowlist (`scripts/lint-artifact-cleanup-allowlist.txt`)
   seeded with the leaks-always + clean-on-success-only sets, then migrate by
   priority order: release `.xcarchive` → simulator boots → result-bundle
   handoff → control-plane `mktemp`.
2. Adopt a shared cleanup primitive (`register_for_cleanup` + single trap) for
   T-R006 rather than per-site traps; this collapses ~30 leaks-always sites
   into one structural fix.
3. Add an explicit `# lint-artifact-cleanup:allow next-line — janitor=<name>`
   annotation for every janitor-managed call site, so the dependency is local
   and auditable.
4. Treat the simulator-boot/shutdown asymmetry as a contract issue: no boot
   without a paired finalize step, even on aborted runs.

## Reproducibility

This audit was produced from the working tree at commit `cdbc6e9`. Re-running
the same grep-based methodology at the same SHA reproduces the call-site
counts. The methodology and corpus globs are stable across re-runs.
