---
name: iOS Isolated Execution Contract
schema_version: 1
description: Studio v2 contract for isolated iOS project execution, build/test affinity, source-branch integration, artifacts, and privacy.
type: contract
---

# iOS Isolated Execution Contract

This contract defines how Studio v2 executes iOS project work without sharing a
writable checkout, Xcode cache, simulator, or integration branch between
concurrent jobs. It is normative for the v2 iOS execution chain; implementation
mechanics land in follow-up issues.

The contract restores the v1 safety guarantees in host-agnostic terms:

- work runs in isolated worktrees or clones created from the intended task
  source branch;
- completed work integrates into the chain branch, not directly into the source
  branch;
- same-source-branch chains serialize integration through explicit locks;
- build/test artifacts are scoped to the chain, lane, executor, and run that
  owns them;
- deterministic scripts own orchestration, locks, queues, cache keys, and
  artifact publication. LLM sessions may plan, implement, review, and interpret
  failures, but must not be the source of truth for routing or lock state.

## Job Classes

| Job class | Execution model |
|---|---|
| Normal implementation | Manager creates an issue branch and isolated issue worktree from the chain branch. The worker writes only scoped code/docs/tests and a private completion summary. Parent chain integration happens after review gates pass. |
| Build/test | Routed through the project profile operation (`build`, `test:unit`, `test:ui`) and an execution policy. Build/test prefers chain affinity to reuse warmed DerivedData and simulator state, but concurrent lanes never share one writable DerivedData root. |
| Review | Reviewers read the issue diff, plan/outcome artifacts, and bounded evidence. Reviews may run build/test jobs through the same artifact and simulator slot contract, but review verdicts do not mutate source branches. |
| Release/TestFlight | Release jobs inherit the isolated execution model and add release-manager authority, signing/secret scope checks, and human approval boundaries. Secret-bearing release work may break ordinary affinity only through an explicit routing reason. |
| Research, audit, docs, planning | These jobs may parallelize more broadly because they do not benefit from DerivedData affinity and should avoid occupying build/test lanes unless they invoke profile operations. |

## Branches And Worktrees

| Surface | Responsibility |
|---|---|
| Source branch | The eventual PR base, usually `main` or a release line. It is treated as read-only during issue execution. Two chains that target the same source branch must not merge, push, or finalize concurrently without the source-branch integration lock. |
| Chain branch | The integration branch for one chain run, for example `feature/ios-v2-execution`. It accumulates completed issue slices and is the only branch the chain runner advances during issue integration. |
| Issue branch | One branch per issue slice, derived from the chain branch at launch. The worker commits here only. It must not merge sibling branches, close issues, open PRs, or commit private `.studio` artifacts. |
| Isolated worktree/clone | The filesystem checkout for one issue or chain integration lane. It is disposable, run-namespaced, and created fresh for every concurrent issue slice. |

Sequential chain work may reuse a chain-scoped integration cache. Concurrent
task worktrees must use fresh independent worktrees and lane/executor-scoped
writable caches inside the chain artifact root.

## Same-Source-Branch Serialization

When two chains target the same source branch:

1. Each chain still receives its own chain branch, issue branches, worktrees,
   artifact root, affinity state, and queue state.
2. Implementation, review, research, and docs jobs may proceed independently
   when their write sets and artifact lanes are isolated.
3. Any operation that merges, pushes, or finalizes against the shared source
   branch must acquire the source-branch integration lock.
4. The lock owner records run id, chain, source branch, acquired time, and
   intended mutation. Stale-lock recovery is script-owned and audited.
5. Branch integration mechanics are canonical in the source-branch integration
   implementation; this contract owns only the invariant that same-source
   branch mutation is serialized.

## Execution Policy

Chain manifests may declare a policy block so routing and artifact behavior are
visible before execution:

```yaml
execution_policy:
  build_test_affinity: chain
  derived_data_scope: chain-lane
  prefer_local_manager: true
  max_affinity_queue_wait_sec: 900
  artifact_retention: default
  offload_economics: required
```

Field meanings:

| Field | Meaning |
|---|---|
| `build_test_affinity` | `chain` means the first eligible executor selected for a chain's build/test work becomes preferred for later build/test jobs in the same chain. `none` disables that preference. |
| `derived_data_scope` | `chain-lane` means writable DerivedData roots are scoped by chain, lane, executor, and cache key. `issue` forces per-issue roots. |
| `prefer_local_manager` | Normal build/test jobs try the manager first when the manager is eligible and responsive. |
| `max_affinity_queue_wait_sec` | Upper bound for waiting behind affinity before considering an affinity break. |
| `artifact_retention` | Retention class selector. `default` uses the contract tiers below unless a stricter profile/release policy applies. |
| `offload_economics` | `required` means remote worker offload must pass capability, health, load, queue, lock, and cost checks before routing away from the manager. |

## Routing Eligibility

Local-manager-first is the default for normal tasks. The manager remains
eligible only if it can run the job without exceeding the configured
control-plane responsiveness budget for status, dry-run, scheduler heartbeat,
and operator prompts. The concrete budget is owned by the later telemetry and
responsiveness work; this contract requires the predicate to exist.

Worker offload is eligible only when all checks pass:

| Check | Requirement |
|---|---|
| Capability | Worker declares the required project profile operation, Xcode version family, simulator runtime/device, SDK, signing/secret floor, and host adapter support. |
| Health | Worker heartbeat, disk, Xcode tooling, simulator services, and source-sync path are healthy. |
| Load | Worker has an available lane for the job class and enough CPU, memory, and disk headroom. |
| Queue | Affinity queue wait is below policy or an allowed affinity-break reason is recorded. |
| Lock | Required source-branch, worker slot, simulator slot, and artifact publication locks can be acquired in order. |
| Cost | Offload is expected to save enough human time, wall-clock time, context, or machine contention to justify sync/retry overhead. For common loops, a >20% latency increase is ask-tier unless safety-critical; a 2x+ increase requires explicit approval or async placement. |

If two chains have build/test affinity to the same worker, their build/test jobs
queue on that worker by default. Non-build work may still run on other eligible
executors.

## Release/TestFlight Priority Routing

Release and TestFlight jobs use a stricter routing predicate than normal
build/test work:

| Predicate | Requirement |
|---|---|
| Capability | Candidate declares the `release` role. TestFlight archive routes also require `xcodebuild`. |
| Secret scope | Candidate `secret_scopes` must include every requested release scope, currently `asc` and `slack` for TF/AS work. Missing or empty scopes are a refusal, not a local fallback. |
| Priority | Candidate participates in the shared build queue with `priority: release`, so queued normal task/background entries sort behind the release entry. |
| Approval boundary | Routing can select a capable machine, but external or irreversible release actions still require the release-manager/operator approval gates. |

The release router bypasses ordinary chain affinity with reason
`release_secret_scope_routing`; release jobs are selected capability/secret/
priority-first rather than by generic warm-cache affinity. If no capable
secret-scoped executor exists, the decision is a typed refusal with
`selected_executor: null` and no secret-bearing work starts.

Priority may displace only work that has not started yet. Safe boundaries are:
before job start, after artifact publication, after simulator shutdown, or
after an explicit checkpoint. The queue implementation can prove only the first
case: lower-priority entries still waiting in `build-queue/<node>/` may be
displaced with `safe_boundary: before_job_start` and
`displaced_work_retains_cache_artifacts: true`. If all physical slots are held
by running work, release routing reports `preemption.status: waiting` and
`preemption.refused: true`; it must not kill a running job mid-write.

Required private telemetry:

| Event | Required payload |
|---|---|
| `release_priority_routing_decision` | selected executor or refusal, release channel, required secret scopes, routing reason, queue priority, selected queue wait, preemption status, displaced queued work, and operator approval boundary |
| `build_queue_promoted` | release task, node, skipped queued jobs, skipped count, and wait time when a release entry moves ahead of lower-priority queue entries |

## Worker-Routed Build/Test Failover

Worker-routed build/test failures are classified by
`scripts/studio-ios-check-failover.sh` before a retry or human halt is chosen.
The decision is private runtime telemetry, not a review bypass and not a merge
or issue-closure authority.

Required failure classes:

| Class | Signals | Retry path |
|---|---|---|
| `worker_unavailable` | Worker disappears, SSH/source-sync cannot reach the worker, or the remote harness cannot classify the run. | Retry another eligible worker first; otherwise retry local manager if eligible; otherwise halt. |
| `worker_timeout` | Remote command exits 124 or exceeds the bounded worker timeout. | Retry another eligible worker first; otherwise retry local manager if eligible; otherwise halt. |
| `remote_command_failed` | The command reached `xcodebuild`/test and returned non-zero. | Do not auto-rerun; halt as terminal build/test failure evidence. |
| `artifact_missing` | Required result, summary, log, exit marker, or publication artifact is absent. | Preserve partial artifacts, then retry locally once when eligible; otherwise another worker; otherwise halt. |
| `artifact_malformed` | Published JSON/summary/marker is unreadable or reporting disagrees with publication. | Preserve evidence and halt for operator reconciliation. |
| `sync_drift` | Expected branch, SHA, manifest, run id, chain-run id, or issue-run id does not match worker/local state. | Missing/stale proof may refresh source sync under the same run identity; mismatches halt for human realignment. |

Additional typed outcomes are allowed for policy edges: `stale_lock`,
`cache_poisoning`, `simulator_slot_timeout`, `simulator_stuck_boot`,
`simulator_erase_failure`, `simulator_runtime_mismatch`, and
`simulator_stale_slot_reclaimed`.

Retries are finite. The default retry budget is two failover retries
(`STUDIO_IOS_FAILOVER_MAX_RETRIES=2`) and every retry keeps the original
`run_id`, `chain_run_id`, and `issue_run_id`. A retry must publish its selected
path (`retry_another_worker`, `retry_local`,
`retry_same_worker_after_source_sync`, `reclaim_stale_lock_then_retry`,
`quarantine_cache_then_retry_*`, or a halt path) and the final decision outcome
(`retry_planned`, `terminal_failure`, or `halted`).
Retry budget state is durable private runtime state keyed by chain-run id,
issue-run id, task id, and operation; it must not derive only from a gate-local
attempt counter that can reset between parent-triggered retries.

Failover idempotency keys are separate so artifact publication and result
reporting can be reconciled independently. They use the durable retry sequence
from failover state, not the gate-local attempt counter:

```
ios-check:<chain-run-id>:<issue-run-id>:<task-id>:<operation>:failover:r<retry-count>:<failure-class>
ios-check:<chain-run-id>:<issue-run-id>:<task-id>:<operation>:result:r<retry-count>
ios-check:<chain-run-id>:<issue-run-id>:<task-id>:<operation>:artifact:r<retry-count>
```

A retry path that depends on executor eligibility requires a valid router
decision or live router explanation. Missing, malformed, or failed routing
context is a typed operator halt, not an implicit local retry.

Failover never commits issue work, closes issues, posts duplicate PR comments,
rewrites shared branch history, or bypasses plan/outcome/PR review gates. Those
side effects remain parent-runner or reviewer-gate responsibilities keyed by
their own idempotency surfaces.

## Chain Affinity State

The manager owns chain affinity and queue policy. Workers may emit events about
observed cache warmth, slot state, or failures, but they must not independently
rewrite affinity state.

State is private runtime data under the chain-run artifact root, mirrored into
the manager status view when needed:

```json
{
  "schema_version": 1,
  "kind": "ios-chain-affinity",
  "chain": "ios-v2-execution",
  "source_branch": "main",
  "preferred_executor": "manager",
  "derived_data_cache_key": "xcode16_4-ios18_4-app-debug-abc123-manager",
  "set_by_job": "example-job-id",
  "set_at": "2026-05-08T00:00:00Z",
  "expires_at": "2026-05-09T00:00:00Z",
  "last_reused_at": null,
  "last_break_reason": null
}
```

The idempotency key is:

```
chain + source_branch + profile + operation_family + cache_key + executor_id
```

Affinity expires when the chain completes, the cache key changes, the executor
becomes unhealthy, the cache is invalidated, or the configured stale-affinity
TTL elapses. Recovery must be deterministic: mark stale, clear or break
affinity with a reason, then route through normal eligibility.

Required private events:

| Event | Required payload |
|---|---|
| `ios_affinity_set` | chain, executor, cache key, job id, reason |
| `ios_affinity_reused` | chain, executor, cache key, job id, queue wait |
| `ios_affinity_broken` | chain, previous executor, selected executor, reason, actor |
| `ios_affinity_cleared` | chain, executor, reason, actor |

Allowed affinity-break reasons are queue delay threshold, worker health failure,
capability mismatch, urgent priority, release/TestFlight secret-scope routing,
cold or invalid cache, disk pressure, manager responsiveness, and user override.

## DerivedData And Cache Keys

The v2 cache key for DerivedData reuse must include every input that can make
build products incompatible:

- Xcode version;
- simulator runtime and device family when tests are involved;
- SDK;
- scheme;
- configuration;
- package graph hash;
- source branch and base commit;
- build settings hash;
- executor identity when paths, signing, toolchains, or simulator catalogs are
  executor-sensitive.

Writable DerivedData roots must be safe path segments and scoped by policy.
The iOS project profile command layer implements the chain-scoped artifact
shape as:

```
<chain-artifact-root>/
  DerivedData/
    integration/<cache-key>/
    lanes/<executor-or-lane-id>/<cache-key>/
  result-bundles/<issue-run-id>/<attempt-operation>.xcresult
  logs/<issue-run-id>/<attempt-operation>.log
  summaries/<issue-run-id>/<attempt-operation>.summary.txt
  tmp/<issue-run-id>/<attempt-operation>/
```

Sequential build/test jobs in one chain may reuse a chain-lane root when the
cache key matches. Concurrent lanes must not write the same DerivedData root.
Read-only cache warming or artifact copying is allowed only through
script-owned atomic publish/consume steps.

Each DerivedData root has a sibling `<derived-data-path>.metadata.json` file
with `schema_version`, `cache_key`, writer run identifiers, path pointers, and
the cache-key inputs used by the writer. Reuse fails closed: if required inputs
are missing, metadata is unreadable, schema version is unknown, or the stored
cache key mismatches, the profile command uses a fresh cold root instead of
sharing writable build products.

Debugging overrides are explicit environment variables:
`STUDIO_IOS_ARTIFACT_ROOT` or `STUDIO_CHAIN_ARTIFACT_ROOT` for the root,
`STUDIO_IOS_DERIVED_DATA_PATH`, `STUDIO_IOS_RESULT_BUNDLE_PATH`,
`STUDIO_IOS_LOG_PATH`, `STUDIO_IOS_SUMMARY_PATH`, and `STUDIO_IOS_TEMP_DIR`
for individual paths. Raw `xcodebuild -derivedDataPath` and
`-resultBundlePath` arguments are rejected by the profile command so ordinary
invocations cannot silently leak artifacts outside the scoped root.

## Artifact Retention And Janitor Policy

`profiles/ios-turnip/commands/xcode-operation` writes a private retention
record after the operation summary is extracted. The janitor owns deletes,
compression, TTL sweeps, disk-pressure refusal, and redacted cleanup telemetry.
It deletes only inside the scoped artifact root it was given.

| Retention class | Trigger | Default behavior |
|---|---|---|
| `pass-summary-only` | Successful build/test | Delete result bundle, log, and tmp path after summary extraction. Keep DerivedData until the chain completes. |
| `pass-short-retain` | Explicit short-retain override | Retain artifacts briefly, default 24h. |
| `failed-retain` | Failed build/test | Retain evidence for 48h by default. |
| `blocked-retain` | Caller marks blocked | Retain evidence for 48h by default. |
| `aborted-retain` | Caller marks aborted | Retain evidence for 24h by default. |
| `debug-pinned` | `STUDIO_IOS_DEBUG_RETAIN=1` | Requires owner, reason, and expiry. Unbounded pins are invalid. |
| `release-retain` | Release/TestFlight operation | Retain for 30d by default unless a stricter release policy applies. |
| `cache-quarantined` | Cache poisoning, metadata mismatch, or partial-write signal | Move evidence to `quarantine/` and retain 7d by default. |

The chain runner supplies `STUDIO_CHAIN_ARTIFACT_ROOT` under the private
chain-run root for worker sessions. It runs the janitor before new dispatch and
after chain completion. Completed chains clean the iOS artifact root when only
success-path artifacts remain; failed, blocked, debug-pinned, release, and
quarantined artifacts survive until expiry.

Cleanup telemetry is private and path-redacted. Public summaries may mention
counts/classes such as deleted, retained, pinned, skipped, compressed, refused,
and bytes freed, but must not include raw artifact paths.

## Chain Execution Telemetry Roll-up

Worker completion summaries for iOS chain work may include
`execution_telemetry` so chain reports can explain where work ran without
publishing private paths or exact node names. The private summary records:

- `executors.implementation`, `executors.build`, `executors.test`,
  `executors.review`, and `executors.release` when the role was applicable.
- `routing.reason_class`, `routing.cost_summary`, `routing.economics`, queue
  wait, affinity/cache state, and scheduler/control-plane timing.
- `artifacts.private_roots[]` for local reconstruction and
  `artifacts.public_classes[]` for public-safe summaries.
- `cleanup.outcome`, `cleanup.retention_class`, and `cleanup.ttl_class`.
- `failover` retry path, reason class, and final outcome when a worker-routed
  build/test path failed over.

Missing iOS execution evidence is a telemetry gap, not a task-failure override.
Use named gaps such as `implementation_executor`, `build_executor`,
`test_executor`, `review_executor`, `release_executor`, `worker_routing`,
`artifact_evidence`, and `cleanup_telemetry`.

## Locks

Locks must be acquired in this order:

1. scheduler queue;
2. source-branch or chain integration;
3. worker slot;
4. simulator slot;
5. artifact publication;
6. cleanup/janitor.

Code that cannot follow the order must fail before acquiring a later lock. The
cleanup/janitor path must not hold broad locks that block active build/test
execution; it may use only narrow atomic moves or deletes against artifacts it
has proven inactive.

Every stale-lock reclamation path must have a lease, owner identity, heartbeat,
and safe reclamation rule. The minimum lease record fields are `lock_kind`,
`owner_host`, `owner_pid`, `owner_run_id`, `owner_chain_run_id`,
`owner_issue_run_id`, `acquired_at`, `expires_at`, and `heartbeat_at`.
Reclamation is allowed only when the lease expired and the owner PID is dead or
the heartbeat is stale. This applies to scheduler, source-branch, worker slot,
simulator slot, artifact publication, and cleanup locks.

## Simulator Slots

A simulator slot is identified by executor id, runtime, device family, slot
name, UDID, owning job id, acquired time, and lease timeout. Slot state is
private runtime data and may be summarized in status.

A slot is reusable only when:

- its runtime and device match the requested job;
- its lease is active and owned by the current job, or it is idle;
- its previous owner released it or its stale lease was reclaimed by script;
- it is not booting, erasing, deleting, or reserved by another job;
- the job accepts the slot's cleanup mode.

Default cleanup is shutdown/release, not erase/delete. Erase/delete is explicit
janitor work and must not run while the slot is leased.

Simulator recovery outcomes are typed:

| Outcome | Response |
|---|---|
| `simulator_slot_timeout` | Retry another eligible executor or local manager within the retry budget. |
| `simulator_stuck_boot` | Release stale lease, retry once, then reroute or halt. |
| `simulator_erase_failure` | Halt for operator review. |
| `simulator_runtime_mismatch` | Halt for operator review. |
| `simulator_stale_slot_reclaimed` | Continue only after lease expiry plus dead-owner or stale-heartbeat proof. |

## Overrides

Supported user overrides are `force-local`, `force-worker`, `break-affinity`,
and `clear-affinity`. Each override must record private telemetry with actor,
reason, affected chain, affected job, safety checks run, previous routing
decision, resulting routing decision, and expiry when applicable.

Safety checks still apply. `force-worker` cannot bypass missing capability,
secret-scope mismatch, source-branch integration lock, or simulator slot safety.
`force-local` cannot run a manager-local build/test job that would exceed the
control-plane responsiveness budget unless the user explicitly accepts the
operator impact.

## Artifact Classes And Retention

| Artifact class | Examples | Retention expectation |
|---|---|---|
| Private runtime control | `.studio/chain-task-start.json`, worker summaries, affinity state, queue state, lock files | Private and uncommitted. Preserved long enough for parent ingestion, resume, and review; cleaned by chain runner or janitor. |
| Build/test products | DerivedData, module caches, `.xcresult`, logs, screenshots, a11y snapshots | Chain/lane scoped. Success paths may be pruned aggressively; failure paths retain enough evidence for diagnosis according to the active retention tier. |
| Integration artifacts | chain `plan.json`, `state.json`, phase plan/outcome, rule-gate audit | Private under `~/.dev-studio/<project>/chain-runs/<run_id>/`; retained for chain reports and debug windows. |
| Public artifacts | PR title/body, issue comments, release notes, tag notes | Must contain only public-safe summaries and links to public commits/PRs. No raw private prompts, logs, telemetry, paths, secrets, or proprietary incident details. |
| Telemetry summaries | event counters, duration, checks run, cache warmth, affinity-break reason | Private by default. Public summaries must be aggregate and redacted. Missing fields are explicit telemetry gaps, not inferred facts. |

## Queue And Status View

The status view must expose, at a high level:

- active chains and source branch;
- preferred executor and whether affinity is warm, cold, stale, or broken;
- queued jobs and active job per chain;
- worker lane and simulator slot occupancy;
- cache warmth and cache key;
- disk pressure;
- retained artifact counts/classes;
- held locks and lock owners;
- affinity-break reasons and user overrides.

The view is a derived read model. It must be rebuildable from private runtime
state and events; workers do not edit it directly.

## Edge Cases

| Edge case | Contract response |
|---|---|
| Affinity pile-up | Queue up to `max_affinity_queue_wait_sec`, then break affinity only with a recorded reason or user override. |
| Stale cache invalidation | Recompute the cache key, mark old cache stale, route through normal eligibility, and never share stale writable DerivedData. |
| Source-branch merge serialization | Proceed with isolated work, but block merge/push/finalize until the source-branch integration lock is acquired. |
| Worker disappearance | Expire leases, mark worker unhealthy, clear or break affinity, and preserve artifacts already published. |
| Simulator contention | Queue for an eligible slot or route to another eligible executor; never let two jobs own one slot lease. |
| Priority inversion | Urgent or release/TestFlight jobs may break affinity with telemetry and safety checks. |
| Cache poisoning | Quarantine cache by key, executor, and chain; rerun cold and retain evidence for janitor/review. |
| Manager overload | Manager-local build/test becomes ineligible when it would exceed the control-plane responsiveness budget. |
| Path drift | Executor-sensitive paths are part of the cache key; source sync must fail loud on path mismatch. |
| Disk pressure | Disk pressure makes build/test offload or local routing ineligible until cleanup frees space or the user overrides non-destructively. |

## v1 Migration Capture

Before implementation, capture these legacy iOS assumptions as explicit data or
documented defaults:

- source branch workflow and PR base selection;
- worktree and branch naming;
- merge-back behavior and leaf history policy;
- DerivedData, result bundle, and build log paths;
- worker routing hints and remote source-sync behavior;
- simulator lock names, slot counts, and cleanup timing;
- artifact cleanup timing for success and failure paths;
- known operator overrides and the safety checks they bypassed or preserved.

The migration output must be sanitized for public issue/PR text. Detailed local
paths, private logs, raw prompts, names, task IDs, branch names from product
work, and secret-bearing release details stay in private runtime artifacts.
