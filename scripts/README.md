# Worker fleet

File-based IPC that lets one manager session dispatch tasks to N independent
worker panes. Each worker is a long-running shell loop that spawns a
fresh `claude -p "/dev-studio worker <id>"` per task — clean context every time, no
harness changes required.

**Multi-project:** each project gets its own independent fleet, resolved
automatically from the git toplevel basename. Run one manager + N workers
per project. Cross-project one-offs: `ACHILLES_PROJECT=<slug>`.

## Setup

```sh
brew install fswatch coreutils yq jq shellcheck   # coreutils gives gtimeout; yq drives post-2.6 YAML reads; jq drives event normalization + read-events.sh; shellcheck lint-checks scripts
pip install check-jsonschema           # JSON Schema contract validation (validate-contract.sh); pip3 works too
chmod +x scripts/*.sh
```

## Daily flow

Open N terminal panes (typical: 6). Easiest with iTerm **Broadcast Input** (`Cmd+Opt+I`) — type the same command once, every pane runs it, and each pane atomically claims the lowest free slot:

```sh
scripts/achilles-worker.sh        # auto-claims slot 1, 2, 3, … per pane
```

Or pin slots explicitly:

```sh
scripts/achilles-worker.sh 1
scripts/achilles-worker.sh 2
```

Slot ownership is held by `worker-N/.lock` (an atomic `mkdir`). When a pane exits, the lock is released. A stale heartbeat (>180s) lets a new pane reclaim that slot automatically. Cap the auto-claim scan with `ACHILLES_MAX_SLOTS` (default 16).

Worker panes auto-title as `<project>:worker-N` (iTerm/tmux OSC 0) so you can tell at a glance which project each pane belongs to.

After each dispatched task, the pane prints the last 40 lines of `worker.log` so questions or errors from the subagent are visible without tailing the log from a separate pane.

**Stuck-state detection:** if `claude -p` exits `rc=0` but no YAML debrief for the task exists under `~/.dev-studio/<project>/plans/debriefs/`, the worker treats the task as silently stuck (the subagent almost certainly exited after asking a clarifying question the one-shot process could never answer). The task file goes to `rescue/` and a sidecar `<task-id>-stuck.md` captures the flags, timestamp, and last 200 lines of log. Operator decides whether to re-brief and re-dispatch.

In your manager session (or any shell):

```sh
scripts/achilles-dispatch.sh T001              # current project, least-loaded worker
scripts/achilles-dispatch.sh T002 worker-3     # pin to a specific worker
scripts/achilles-dispatch.sh T004 any -- --wait --force-build
ACHILLES_PROJECT=other-app scripts/achilles-dispatch.sh T001   # cross-project
scripts/chanakya-task-train.sh --train export-flow --dry-run    # preview reviewed single-train dispatch
scripts/chanakya-task-train.sh --train export-flow --yes        # plan review, dispatch, watch, outcome review, resumable
scripts/worker-status.sh                       # current project's fleet
scripts/worker-status.sh --all-projects        # machine-wide view
scripts/achilles-cancel.sh T002                # remove a pending dispatch

# Work-stealing queue (preferred for batch dispatch):
scripts/achilles-queue.sh enqueue T001         # append to pending queue
scripts/achilles-queue.sh drain                # hand head-of-queue to each free worker
scripts/achilles-queue.sh list                 # inspect queue
scripts/achilles-queue.sh depth                # integer queue depth
scripts/achilles-queue.sh clear                # wipe queue (abort scenarios only)

# Usage analysis (read-only, from this repo — see ANALYSIS.md):
scripts/analyze-collect.sh --project turnip-ios         # stats dump for a usage-analysis pass
scripts/analyze-collect.sh --project turnip-ios --since 2026-04-01
scripts/forge-latency-report.sh --project turnip-ios --days 14   # stage-level task latency + review-gate comparison
scripts/field-workflow-report.sh --project turnip-ios --days 14   # Field loop timing, tokens, gates, review coverage, improvement candidates
scripts/studio-weekly.sh --post                                  # weekly GitHub PM digest comment on the pinned summary issue
scripts/studio-chain-runner.sh workflow-measurement-improvements            # default plan/explain + private resumable state
scripts/studio-chain-runner.sh workflow-measurement-improvements --dry-run  # same resolved graph, then non-mutating command trace
scripts/studio-chain-runner.sh workflow-measurement-improvements --host codex --yes # execute after plan with node/RAM-sized session pool + private report
scripts/studio-chain-runner.sh my-chain --dry-run                          # object-form issues may declare dependencies/depends_on; ready independent issues fill worker_pool
STUDIO_CHAIN_TARGET_REPO_ROOT=/repo scripts/studio-chain-runner.sh /tmp/chain.yaml --dry-run # run a non-repo manifest against an explicit checkout
scripts/studio-chain-runner.sh workflow-measurement-improvements --checkpoint auto --dry-run # preview role/branch-scoped checkpoint hooks
scripts/studio-chain-runner.sh --discover                                  # bare invocation lists runnable chains, resumable runs, and next actions
scripts/studio-chain-runner.sh --discover ios-v2-execution                 # filtered discovery for one chain, chain id, or manifest
/dev-studio manager work-chain ios-v2-execution --dry-run                  # preferred user-facing preview path
/dev-studio manager work-chain --resume <run_id> --yes                     # preferred user-facing resume path from summaries/halt records
scripts/manager-plan-chain.sh --issue 758 --repo v-i-s-h-a-l/generic-dev-studio --execute # reviewed source/issue to unattended issue-backed work-chain execution
scripts/manager-work-chain.sh --from-plan task-graph.json --chain my-chain # plan-chain gate, native issue links, Project fields, then unattended execution
/dev-studio manager work-chain --doctor <run_id>                           # preferred read-only recovery recommendation for an existing run
scripts/manager-work-chain.sh ios-v2-execution --dry-run                   # preview the named chain through the manager front door
scripts/studio-chain-runner.sh --auto workflow-measurement-improvements     # unattended start/resume when state is safe and unambiguous
scripts/studio-chain-runner.sh workflow-measurement-improvements --attended --yes # attended execution with explicit confirmation bypass
scripts/studio-chain-runner.sh workflow-measurement-improvements --unattended --yes # execute without routine continuation prompts; typed blockers halt
scripts/studio-chain-runner.sh --explain-next workflow-measurement-improvements # show the supervisor's next action without mutating state
scripts/prd-intake-normalize.sh prd.md                                     # normalize PRD/transcript/issue brief language into a requirement packet
scripts/prd-task-graph-synthesize.sh packet.md                             # synthesize deterministic scheduler graph; flags missing prereqs, write races, and unbounded tasks
scripts/studio-chain-runner.sh --resume <run_id> --yes                     # resume from state.json; reconciles completed worker summaries before scheduling dependents
scripts/studio-chain-runner.sh --list                                      # list persisted chain runs and report paths
scripts/studio-chain-runner.sh --regenerate-report <run_id>                # opt-in refresh for stale private chain-run reports
scripts/studio-chain-runner.sh --doctor <run_id> --public-safe             # read-only recovery recommendation with local paths/details redacted
scripts/studio-chain-runner.sh workflow-measurement-improvements --only chain-a --dry-run  # one manual shell per independent chain; dry-run before parallel execution
scripts/studio-chain-rule-gates.sh --plan plan.json --dry-run              # deterministic rule-pack gates with typed JSON result + audit JSONL
scripts/studio-ios-artifact-janitor.sh sweep --base /tmp/studio-ios-artifacts --json # redacted iOS artifact TTL sweep for scoped build/test roots
scripts/studio-ios-check-failover.sh decide --operation build --task-id T001 --selected-executor worker-a --failure-signal remote_timeout # typed retry/halt policy for worker-routed iOS checks
scripts/rule-pack-resolve.sh --manifest chain.yaml --chain my-chain --issue 123 --role worker # selective rule-pack selection with context-budget telemetry
scripts/manager-chain-monitor.sh status --project generic-dev-studio --json # non-mutating monitor status with owner/list/archive pending-write counts
scripts/manager-chain-monitor.sh recovery --full-rewrite --project generic-dev-studio --dry-run # explicit recovery front door; execution requires approval
scripts/schedule-chain-monitor.sh --install --project generic-dev-studio --interval-s 300 # login-home macOS LaunchAgent for background monitor sync
scripts/studio-chain-telemetry-digest.sh --project turnip-ios --public-safe --days 7 # project-filtered rollup with redacted paths, gaps, halts, retries, and review verdicts
scripts/lint-chain-workflow-docs.sh --staged                               # guard chain launcher docs, usage text, and fixtures; bypass with STUDIO_BYPASS_CHAIN_WORKFLOW_DOCS=1
scripts/lint-html-theme.sh --staged                                        # guard generated HTML theme parity; bypass with STUDIO_BYPASS_HTML_THEME_GUARD=1
scripts/studio-checkpoint.sh create --role worker --goal "..." --next "..." # compact private checkpoint; stdout prints the checkpoint id
scripts/studio-checkpoint.sh resume --checkpoint-id <id> --role worker      # load by id, falling back to durable project indexes, then inspect drift lazily
scripts/codex-worker-exec.sh "<prompt>"                                    # internal Codex worker launcher: workspace-write + ~/.dev-studio + ephemeral + no prompts
# Chain dry-runs show the selected git metadata strategy; sandboxed hosts use issue-local clones so commits stay inside the worker root.
# Chain worktrees/results are namespaced under the run UUID; resume continues only the selected run, reconciles stale running issues from completed private summaries after required outcome review, and surfaces skipped/integrated/pending issue semantics.
# Chain startup sweeps stale state locks, old temporary run roots, scoped iOS artifact roots, and oversized private artifacts; tune with STUDIO_CHAIN_TMP_RETENTION_DAYS, STUDIO_CHAIN_RUN_RETENTION_DAYS, STUDIO_CHAIN_ARTIFACT_MAX_BYTES, and STUDIO_IOS_ARTIFACT_* TTL/pressure settings.
# Chain reports include compact efficiency metrics, test/lint/build outcomes, typed halt records, and decision escrow when automation pauses or continues on a low-risk default.
# Chain manifest preflight rejects planning artifacts before run creation; project-scoped manifests declare issue_repo or resolve it from the target repo remote.
# Release-bearing chain manifests declare approved_release_id plus sync_strategy; rebase is the default, and squash is used only when the manifest explicitly opts in.
scripts/studio-chain-reviewed.sh v2-transition --host codex --review-host claude-reviewer  # pre-run phase review, then chain PRs reviewed by the selected reviewer
scripts/host-preflight.sh codex /repo                 # gh/git credential proof plus ShellCheck availability before host task work
scripts/studio-project-state.sh --status Todo         # field-aware backlog reader for the Studio v2 Projects board
scripts/studio-gh.sh issue list --state open          # gh wrapper for narrow issue lookups; uses context github_home for auth
scripts/studio-dependency-export.sh --issue 443       # Mermaid graph from native GitHub blocked_by dependencies; no body parsing
scripts/issue-body-edit.sh 463 --repo owner/repo --body-file generated.md --apply  # guarded issue body replacement; dry-run unless --apply; STUDIO_BYPASS_ISSUE_BODY_GUARD=1 is user-controlled emergency/debug bypass
scripts/studio-staleness-triage.sh --json             # dry-run PM issue staleness plan; --apply labels stale/escalated/archive-candidate issues and posts idempotent comments

# Parent-side GitHub auth:
# assistant-initiated calls use scripts/studio-gh.sh; migrated auth probes use context github_home
# legacy gh/PR/issue call sites use with_login_home_for_github until their context migration lands
# STUDIO_BYPASS_PARENT_HOME_FLIP=1   preserve caller HOME for intentional isolation tests

# Chain runner pool sizing:
# default = 1 local session + one per healthy xcodebuild offload node, RAM-capped at 6 GiB/session
# STUDIO_CHAIN_WORKER_POOL=N      explicit emergency override
# STUDIO_CHAIN_MAX_WORKERS=N      clamp auto-detected pool
# STUDIO_CHAIN_WORKER_RAM_GIB=N   adjust RAM heuristic
# STUDIO_CHAIN_NODE_HEALTH_TIMEOUT_S=N  bound each auto-pool node-health probe; degraded probes are logged and excluded

# Event log reader (dedupes on producer.agent + idempotency_key; see _shared/contracts/event-emission.md):
scripts/read-events.sh                                  # current project, deduped
scripts/read-events.sh --agent worker --event task_completed --tail 20
scripts/read-events.sh --project turnip-ios --since 2026-04-18 --until 2026-04-22

# Event writer — CLI wrapper over emit_event_keyed; validates JSON + 4KB cap.
scripts/write-event.sh --agent worker --event task_completed --task T001 \
    --data '{"merge_sha":"abc1234"}' --mode task

# Ledger library (sourced by extraction scripts; see _shared/patterns/dual-write-transition.md):
#   scripts/lib-ledger.sh       dual-write helpers for plans/<kind>/*.yaml + legacy surfaces
#   scripts/lib-fixtures.sh     scrub-timestamps + YAML/event multiset asserts for fixture replay

# Manager status mode — mechanical extractions from historical status mode payloads (Phase 2.6.5):
scripts/status-load-snapshots.sh                        # 4-domain freshness + detached rewarms; prints {domain: {state, age_s, payload}}
scripts/status-fallback-loaders.sh briefs               # full-load when snapshot misses: briefs|debt|feedback|events-tail
scripts/status-render-tasks.sh < briefs-payload         # stdin JSON → markdown task table
scripts/push-queue.sh list                              # unread entries on stdout
scripts/push-queue.sh mark-displayed <id>...            # clear after surfacing
scripts/status-domain.sh rounds                         # one-line round summary (prefers YAML; legacy fallback)
scripts/status-domain.sh releases                       # one-line release summary + push-tf suggestion
scripts/release-manager-configure.sh --project <slug> --quick --tf-slack-channel C... # release notification setup
scripts/studio-tf-slack.sh draft --context ctx.json --commits commits.txt # durable, linted TestFlight Slack draft artifact
scripts/studio-tf-slack.sh send --draft draft.json --approve              # approval-gated parent/thread Slack post + events

# Reviewer pipeline — mechanical extractions from the v2 reviewer role contract:
eval "$(scripts/argus-setup.sh T001 S /path/to/worktree)"           # marker + review_requested + trap line
TASK_ID=T001 eval "$(scripts/argus-diff-extract.sh /path main)"     # BASE_SHA + DIFF_PATH + scope-cap events
scripts/argus-classify-diff.sh /tmp/argus-T001-diff.txt             # JSON diff signals for selective rule loading
scripts/argus-select-rules.sh '{"touches_swiftui":true}' core/v2/reviewer/rules # JSON load/skipped rule-pack lists
scripts/argus-run-tests.sh T001 MyScheme MyTests                    # xcodebuild + test-slot mgmt; exit 0 green, 3 red
scripts/argus-verify-tdd.sh T001 /path main MyScheme MyTests        # red→green verify; exit 0 ok, 2 flag, 3 block
scripts/argus-emit-verdict.sh T001 approved '[]' --task-uuid <uuid> # YAML verdict + back-ref + event + stdout line
scripts/emit-agent-session-completed.sh argus review T001 auto:T001 --verdict approved   # shared session-close (any agent); auto: resolves start-ts from emit-agent-boot stamp

# Manager inbox sweep — mechanical extractions from historical inbox-sweep payloads (Phase 2.6.5):
scripts/sweep-enumerate-debriefs.sh                     # stdout: canonical ingest queue (debrief/build-check/release); stderr: blind-spot diagnostics
scripts/sweep-ingest.sh debrief <path> [--argus-exempt] # Step 0A — task + direct-debrief ingest (follow-ups, back-refs, state flip)
scripts/sweep-ingest.sh build-check <path>              # Step 0B — debt counter reset/hold, TBUILD auto-file on red
scripts/sweep-ingest.sh release <path>                  # Step 0B2 — release artifact + per-task release back-ref
scripts/sweep-threshold-actions.sh                      # Step 0C — warn@6 files TBUILD, block@12 sets state flag
scripts/sweep-janitor.sh all                            # Step 0D — worktrees/feedback-assets/orphans/scaling-alerts (honors DRY_RUN)
scripts/sweep-process-events.sh                         # Step 0E — event fan-out (drain / push-queue / follow-ups / drift log)
scripts/sweep-feedback-reminders.sh                     # Step 0E2 — emits feedback_reminder_due for past-due rows
scripts/lib-sweep-timing.sh                             # best-effort sweep_phase_completed timing helper
scripts/sweep-adaptive-backoff.sh 1                     # Step 0G — 900→1800→3600→7200 on blank; reset 900 on activity
scripts/push-queue.sh append --kind review_blocked --task T001 --text "..."   # used by sweep + argus

# Manager test-manifest + test-flow — extractions from historical tests payloads (Phase 2.6.5):
scripts/tests-dirty-state-check.sh <path>               # exit 2 if user-testing.md has checked boxes or Notes
scripts/tests-scan-candidates.sh                        # enumerate merged + user-verifying tasks
scripts/tests-pull-cases.sh <task-id>                   # YAML `cases:` block from debrief YAML; historical sidecar import fallback
scripts/tests-write-manifest.sh [--force]               # stdin YAML → plans/user-testing.md
scripts/tests-write-round.sh <N> <scope> <tasks-csv> <body-file>   # round artifact via lib-ledger write_round_artifact
scripts/tests-promote-round.sh <N>                      # gate-check + pre-checked manifest; exit 3 on gate fail
scripts/tests-diff-rounds.sh <A> <B>                    # markdown diff between rounds

# Worker task mode — mechanical extractions from historical task payloads (Phase 2.6.5):
eval "$(scripts/task-load-spec.sh T001)"                # TASK_MODE/BRIEF_PATH/SIZE/TYPE/ACCEPTANCE_JSON
scripts/task-build-debt-gate.sh [--override]            # exit 2 if blocked; emits build_debt_blocked
scripts/task-claim.sh <task-uuid> <brief-uuid> <size>   # task + brief state transitions
eval "$(scripts/task-worktree-setup.sh T001 /repo)"     # PROJECT/ORIG_BRANCH/ORIG_HEAD/WORKTREE; reuses the chain runner's feature-branch gate so dependent branches rebase/retarget instead of merging feature-to-feature
scripts/task-build-gate.sh lsp-only T001 /wt MyScheme "platform=iOS Simulator" [zaps-app/Turnip.xcodeproj] # lsp-only stays local; full-green xcodebuild routes through studio-ios-check-router.sh, then queue/lock; exit 4 = duplicate-invocation refused (#209)
scripts/studio-ios-check-failover.sh decide --operation test --task-id T001 --selected-executor worker-a --failure-signal artifact_missing # emits finite retry/halt telemetry and retains partial logs when STUDIO_CHAIN_ARTIFACT_ROOT is set
scripts/studio-tf-push.sh push [--version X.Y.Z]        # TestFlight push driver; creates/pushes tf-<version>-<build> anchor
scripts/studio-tf-push.sh withdraw-tf-tag --version X.Y.Z --build N # rename TF anchor to tf-<version>-<build>-WITHDRAWN
scripts/node-parity.sh [--fix|--dry-run]                # probe + cache toolchain versions; optionally install missing brew packages and print manual Xcode/runtime fixes (#126/#131)
scripts/check-xcode-parity.sh m1mini                    # pre-dispatch guard; exit 1 = MAJOR Xcode drift; STUDIO_IGNORE_XCODE_DRIFT=1 overrides (#136)
scripts/node-warmup.sh m1mini [project]                 # async-safe pre-dispatch source sync + package cache warm-up (#138)
scripts/task-write-test-cases.sh T001 '[{...}]'         # stdout debrief `tests.added` payload; no standalone sidecar write
scripts/task-write-self-review.sh T001 '{...}'          # writes plans/self-reviews/T001.yaml with same-host findings/fixes before final verification
scripts/task-invoke-argus.sh T001 /wt main S            # emits review_requested with reviewed base SHA (reviewer invoked through dispatch wrapper)
scripts/task-merge.sh T001 /wt feature-branch --require-approved  # merge lock + approved-only policy + post-review base re-check
scripts/node-janitor.sh [--days N] [--dry-run]          # periodic node-side sweep of stale derived-data + worktrees + dispatch logs/registry (#129, #272); LaunchAgent-driven
scripts/install-node-janitor-launchagent.sh             # render + load every-6h LaunchAgent on the local node (auto-run by bootstrap --worker)
scripts/monitor-install.sh install                      # opt-in laptop LaunchAgent; hourly node-health monitor + notifications for >6h unreachable nodes (#132)
scripts/node-monitor.sh                                 # one-shot monitor check; tracks streak/cooldown state and emits node_unreachable alerts (#132)
scripts/task-emit-debrief.sh <task-uuid> <brief-uuid> self-reviewed '{...}'   # YAML debrief + state flips
scripts/studio-tf-push.sh appstore --build N --version X.Y.Z --release-notes-file notes.txt --whatsnew-file whatsnew.txt # backend for /fullSendToAppStore; creates GitHub draft, submits ASC, and records Slack/PR handoff

# Manager reconcile/analyze + studio-feedback ingestion:
scripts/manager-reconcile.sh --cwd "$PWD"               # project repo: sync emitted debriefs/reports into the project task ledger
scripts/manager-analyze.sh --cwd "$PWD"                 # studio repo: telemetry/log analysis plus studio feedback triage
scripts/ingest-feedback.sh                              # idempotent feedback route: create/comment/defer; silent outside generic-dev-studio
scripts/analyze-feedback-ingest.sh --apply              # studio-feedback durable routing: search/comment/create, then processed/
scripts/feedback-retroactive-sweep.sh --project generic-dev-studio --since YYYY-MM-DD [--apply] # recover missed `(studio-feedback)` / `(studio feedback)` transcript prompts

# Studio PR autopilot primitives (#318):
scripts/pr-reviewer-eligibility.sh codex-reviewer       # no-prompt/no-secret reviewer preflight + real verdict-emitting smoke gate
scripts/pr-reviewer-eligibility.sh claude-reviewer      # same reviewer floor for Claude Code; uses CLAUDE_REVIEWER_HOME + CLAUDE_REVIEWER_CONFIG_DIR
scripts/phase-review.sh --review-host claude-reviewer --input phase-plan.md --output review.md   # sibling-host phase gate; tries alternate cross-host reviewers, then degraded same-host continuity when needed
scripts/pre-commit-review.sh                            # manual reviewer gate for risky staged diffs; accepts approved/approved_with_fixes only
scripts/lint-commit-message.sh --file .git/COMMIT_EDITMSG # validates studio commit messages for Change-Type and Studio-Host trailers; bypass with STUDIO_BYPASS_COMMIT_TRAILER_LINT=1
scripts/lint-field-review-surfaces.sh --staged          # blocks raw cross-host review snippets outside phase-review wrappers
scripts/v2-role-resolve.sh manager                      # resolve Studio v2 role aliases to canonical role names
scripts/lint-v2-bootstrap.sh --staged                   # blocks pre-A0.5 substrate code outside the A0.4 bootstrap/meta boundary
scripts/lint-v2-enforcement.sh --staged                 # A0.6 Studio v2 SPEC-derived substrate/profile gates
scripts/v2-profile.sh --profile ios-turnip --validate   # validate the A6 project-profile layer and iOS profile
scripts/v2-profile.sh --profile ios-turnip --operation build --project-root /path/to/project --dry-run  # resolve an abstract operation without running it
scripts/studio-ios-check-router.sh explain --operation build --chain my-chain --task-id T001 --source-branch main # local-first iOS build/test route explanation with affinity/economics
scripts/studio-ios-check-router.sh explain --operation release:testflight --role release --requires-secret-scope asc,slack # release/TestFlight capability + secret + queue-priority route explanation
scripts/studio-ios-check-failover.sh decide --operation build --task-id T001 --selected-executor worker-a --failure-signal remote_timeout # classify failover and publish the selected retry or halt path
scripts/v2-cutover.sh --status                          # report A9 v1 archive / v2 traffic-switch status
scripts/v2-cutover.sh --validate                        # validate the A9 cutover manifest and rollback playbook
scripts/lint-build-release-message.sh --file draft.md --channel appstore   # A11 message shape + duplicate lint
scripts/lint-project-skill-links.sh [--host codex]      # repo-local project skill discovery link invariant + repair helper
scripts/pr-headless-review.sh <pr>                      # run smoke-eligible reviewer, then merge only if the reused chain-style feature-branch gate keeps head history linear relative to its base
scripts/pr-headless-review.sh <pr> --no-require-cross-host  # opt out of default independent-provider reviewer policy for explicit non-safety-floor runs
scripts/pr-autopilot.sh <pr> --verdict approved         # post reviewer gate, then merge if non-blocked
scripts/pr-merge-finalize.sh <pr> --method auto         # reuses the chain runner's feature-branch gate; can record release approval with --release-id before merge
scripts/resolve-reviewer-model.sh --review-host codex-reviewer --implementation-host claude-code  # policy-backed reviewer model/profile resolver
scripts/check-model-catalog.sh --print-refresh-checklist # validate model catalog + print official-doc refresh checklist
scripts/recommend-model.sh --size s --kind impl --cross-file-count 3 --novelty-score 1

# Manager sweep-time detections:
scripts/detect-edits.sh --quiet                         # emits brief_edited + debrief_edited

# App Store submission watcher (auto-invoked by every sweep):
scripts/studio-tf-push.sh compose-message --channel testflight < commits.txt # taxonomy-aware release/TestFlight bullet composer
scripts/appstore-watch.sh                               # idempotent; publishes release + promotes PR only at READY_FOR_SALE after release approval is recorded
```

**Why work-stealing over upfront fan-out.** Task durations span 3–5× (XS LSP-only vs. M/L with full `xcodebuild`). Batch-assigning N+1…2N tasks to inboxes upfront leaves fast workers idle while slow ones still have a backlog. The queue hands one task at a time on each `task_completed` event, so every freed worker gets the next pending task.

## On-disk layout

Per-project (the common case):

```
~/.dev-studio/<project>/.runtime/achilles-inbox/
  worker-1/
    alive               # touched every 60s by heartbeat
    busy                # present iff a task is in-flight (contents = task-id)
    inbox/<ts>-<id>.task   # pending dispatches (fswatch target)
    done/<ts>-<id>.task    # completed
    rescue/<ts>-<id>.task  # timed-out or malformed; left alone for operator
    worker.log
  worker-2/
  ...
```

Project slug is resolved by `scripts/lib-paths.sh` in this order:
1. `ACHILLES_PROJECT` env var (explicit override — cross-project dispatch)
2. `$(basename "$(git rev-parse --show-toplevel)")` (normal case)
3. Error with install hint

Full root override: `ACHILLES_INBOX_ROOT=/some/path` bypasses project resolution entirely.

## Task file format

```
task_id=T001
flags=--wait --force-build
dispatched_at=2026-04-18T12:34:56Z
dispatched_from=user@host
```

## Env vars

| Var | Default | Effect |
|---|---|---|
| `ACHILLES_PROJECT` | `$(basename "$(git rev-parse --show-toplevel)")` | Project slug for path resolution — set to dispatch cross-project |
| `ACHILLES_INBOX_ROOT` | `$HOME/.dev-studio/<project>/.runtime/achilles-inbox` | Explicit override — bypasses project resolution entirely |
| `ACHILLES_MAX_SLOTS` | `16` | Upper bound for auto-claim slot scan |
| `ACHILLES_TASK_TIMEOUT_SEC` | `2700` (45m) | Max per-task runtime; needs `gtimeout`. 0 disables. |
| `STUDIO_NODE_HEALTH_TIMEOUT_S` | `10` | Max per-node SSH probe runtime for `node-health.sh`; timed-out probes report `unreachable`. |
| `NODE_BUILD_TIMEOUT` | `1800` (30m) | Max remote build/test command stream per `node-dispatch.sh`; needs `gtimeout` or `timeout`, otherwise the script warns and runs unbounded. |
| `NODE_DISPATCH_TAIL_LINES` | `40` | Remote log lines printed when the detached node runner finishes but its `.exit` marker is missing. |
| `NODE_ARTIFACT_RETRIEVE` | `0` | Set to `1` to pull remote `.xcarchive` / `.xcresult` directories from the node's DerivedData back to the matching local DerivedData after a successful remote Xcode build/test. |
| `NODE_SOURCE_SYNC_MODE` | `auto` | Remote source sync mode: `auto` does one full rsync per session/path, then git-diff selective rsync; `full` and `selective` force either path. |
| `NODE_SOURCE_SYNC_SMOKE` | `0` | Set to `1` to dry-run compare selective sync against a full rsync and fall back to full when they diverge. |
| `NODE_WARMUP_TIMEOUT` | `900` (15m) | Max async node warm-up command stream. The first remote gate invocation per session/node launches warm-up in the background and continues. |
| `STUDIO_IOS_ROUTER_FORCE_LOCAL` | `0` | Force iOS build/test routing to the local manager when scheduler safety checks allow it. |
| `STUDIO_IOS_ROUTER_FORCE_WORKER` | empty | Force iOS build/test routing to a named eligible worker; capability, source-sync, simulator, and secret checks still apply. |
| `STUDIO_IOS_ROUTER_BREAK_AFFINITY` | `0` | Ignore the current chain's preferred build/test executor for one routing decision and record the break reason. |
| `STUDIO_IOS_ROUTER_CLEAR_AFFINITY` | `0` | Clear stale iOS build/test affinity before making the next routing decision. |
| `STUDIO_IOS_ROUTER_REMOTE_SETUP_COST_S` | `120` | Scheduler estimate for remote sync/setup cost in offload economics. |
| `STUDIO_IOS_ROUTER_RETRY_COST_S` | `180` | Scheduler estimate for retry cost when offloaded build/test work fails. |
| `STUDIO_IOS_ROUTER_MIN_SAVINGS_S` | `120` | Minimum manager-wait savings required before offloading away from local. |
| `STUDIO_IOS_ROUTER_OVERHEAD_BUDGET_MS` | `2000` | Routing-script overhead budget recorded in scheduler telemetry. |
| `ACHILLES_UNATTENDED` | `0` | Set to `1` to pass `--dangerously-skip-permissions` for fully unattended overnight runs. |
| `ACHILLES_AUTONOMOUS` | `0` (set to `1` automatically by the worker per task) | Tells the worker subprocess there is no user to answer clarifying questions; it must pick obvious defaults and document them in the debrief. Exported by `achilles-worker.sh` for every `claude -p` subprocess. Do not set manually unless testing. |
| `ACHILLES_DISPLAY_NAME` | derived (see below) | Friendly name for panes / logs. Override per-shell, or pre-bake per-project via `~/.dev-studio/<project>/.display_name` (first non-comment line wins). |
| `STUDIO_CHAIN_EXECUTION_MODE` | `attended` | Default chain execution mode. `--auto` switches to `unattended`; explicit `--attended` or `--unattended` wins for normal runner calls. |
| `STUDIO_BYPASS_CHAIN_SYNC_STRATEGY_GATE` | `0` | Set to `1` only for emergency/debug bypass of unsupported chain `sync_strategy` gate rows. |
| `STUDIO_BYPASS_RELEASE_CHAIN_MANIFEST_POLICY_GATE` | `0` | Set to `1` only for emergency/debug bypass of release-bearing manifest policy gate rows. |
| `STUDIO_BYPASS_CHAIN_LEAF_ANCESTRY_GATE` | `0` | Set to `1` only after explicit approval to integrate a release-bearing leaf that no longer descends from its launch chain commit. |
| `STUDIO_BYPASS_CHAIN_LEAF_MERGE_COMMIT_GATE` | `0` | Set to `1` only after explicit approval to integrate a release-bearing leaf containing post-launch merge commits. |
| `STUDIO_BYPASS_CHAIN_WORKFLOW_DOCS` | `0` | Set to `1` to bypass the chain workflow docs guard in emergency commits; update README, scripts docs, runner usage, and fixtures together instead when possible. |

**Display-name resolution:** `ACHILLES_DISPLAY_NAME` env var → `~/.dev-studio/<project>/.display_name` file → git-remote basename → project slug.

## Caveats

- **`--dangerously-skip-permissions`** disables the harness's permission gate. Only enable
  (`ACHILLES_UNATTENDED=1`) when you trust every brief that lands in the inbox.
- **In-flight cancel** is not supported. `achilles-cancel.sh` removes pending dispatches
  only; to stop a running task, kill the worker pane (`Ctrl-C`) and the next process_task
  iteration will exit cleanly.
- **Rescue files don't auto-retry.** Move them back to `inbox/` yourself once the
  underlying issue is fixed.
- **No PID-recycling guard yet** (see ROADMAP edge cases). Heartbeat staleness is the
  only liveness signal — if a worker pane crashes mid-task, the `busy` file may linger
  until the next worker boots in that slot.
