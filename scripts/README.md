# Achilles worker fleet

File-based IPC that lets one Chanakya session dispatch tasks to N independent
Achilles worker panes. Each worker is a long-running shell loop that spawns a
fresh `claude -p "/achilles <id>"` per task — clean context every time, no
harness changes required.

**Multi-project:** each project gets its own independent fleet, resolved
automatically from the git toplevel basename. Run one Chanakya + N workers
per project. Cross-project one-offs: `ACHILLES_PROJECT=<slug>`.

## Setup

```sh
brew install fswatch coreutils yq jq   # coreutils gives gtimeout; yq drives post-2.6 YAML reads; jq drives event normalization + read-events.sh
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

In your Chanakya session (or any shell):

```sh
scripts/achilles-dispatch.sh T001              # current project, least-loaded worker
scripts/achilles-dispatch.sh T002 worker-3     # pin to a specific worker
scripts/achilles-dispatch.sh T004 any -- --wait --force-build
ACHILLES_PROJECT=other-app scripts/achilles-dispatch.sh T001   # cross-project
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
scripts/studio-chain-runner.sh --auto workflow-measurement-improvements     # unattended start/resume when state is safe and unambiguous
scripts/studio-chain-runner.sh --explain-next workflow-measurement-improvements # show the supervisor's next action without mutating state
scripts/studio-chain-runner.sh --resume <run_id> --yes                     # resume from ~/.dev-studio/generic-dev-studio/chain-runs/<run_id>/state.json
scripts/studio-chain-runner.sh --list                                      # list persisted chain runs and report paths
scripts/studio-chain-runner.sh workflow-measurement-improvements --only chain-a --dry-run  # one manual shell per independent chain; dry-run before parallel execution
# Chain reports include typed halt records and decision escrow when automation pauses or continues on a low-risk default.
scripts/studio-chain-reviewed.sh v2-transition --host codex --review-host claude-reviewer  # pre-run phase review, then chain PRs reviewed by the selected reviewer
scripts/host-preflight.sh codex /repo                 # gh auth + git ls-remote credential-helper proof before host task work
scripts/studio-gh.sh issue list --state open          # gh wrapper for assistant/interactive calls; normalizes synthetic Codex HOME to login HOME
scripts/studio-dependency-export.sh --issue 443       # Mermaid graph from native GitHub blocked_by dependencies; no body parsing
scripts/issue-body-edit.sh 463 --repo owner/repo --body-file generated.md --apply  # guarded issue body replacement; dry-run unless --apply; STUDIO_BYPASS_ISSUE_BODY_GUARD=1 is user-controlled emergency/debug bypass

# Parent-side GitHub auth:
# assistant-initiated calls use scripts/studio-gh.sh; scripts that own gh/PR/issue mutations call with_login_home_for_github
# STUDIO_BYPASS_PARENT_HOME_FLIP=1   preserve caller HOME for intentional isolation tests

# Chain runner pool sizing:
# default = 1 local session + one per healthy xcodebuild offload node, RAM-capped at 6 GiB/session
# STUDIO_CHAIN_WORKER_POOL=N      explicit emergency override
# STUDIO_CHAIN_MAX_WORKERS=N      clamp auto-detected pool
# STUDIO_CHAIN_WORKER_RAM_GIB=N   adjust RAM heuristic

# Event log reader (dedupes on producer.agent + idempotency_key; see _shared/contracts/event-emission.md):
scripts/read-events.sh                                  # current project, deduped
scripts/read-events.sh --agent achilles --event task_completed --tail 20
scripts/read-events.sh --project turnip-ios --since 2026-04-18 --until 2026-04-22

# Event writer — CLI wrapper over emit_event_keyed; validates JSON + 4KB cap.
scripts/write-event.sh --agent achilles --event task_completed --task T001 \
    --data '{"merge_sha":"abc1234"}' --mode task

# Ledger library (sourced by extraction scripts; see _shared/patterns/dual-write-transition.md):
#   scripts/lib-ledger.sh       dual-write helpers for plans/<kind>/*.yaml + legacy surfaces
#   scripts/lib-fixtures.sh     scrub-timestamps + YAML/event multiset asserts for fixture replay

# Chanakya status mode — mechanical extractions from modes/status.md (Phase 2.6.5):
scripts/status-load-snapshots.sh                        # 4-domain freshness + detached rewarms; prints {domain: {state, age_s, payload}}
scripts/status-fallback-loaders.sh briefs               # full-load when snapshot misses: briefs|debt|feedback|events-tail
scripts/status-render-tasks.sh < briefs-payload         # stdin JSON → markdown task table
scripts/push-queue.sh list                              # unread entries on stdout
scripts/push-queue.sh mark-displayed <id>...            # clear after surfacing
scripts/status-domain.sh rounds                         # one-line round summary (prefers YAML; legacy fallback)
scripts/status-domain.sh releases                       # one-line release summary + push-tf suggestion

# Argus review pipeline — mechanical extractions from argus/SKILL.md (Phase 2.6.5):
eval "$(scripts/argus-setup.sh T001 S /path/to/worktree)"           # marker + review_requested + trap line
TASK_ID=T001 eval "$(scripts/argus-diff-extract.sh /path main)"     # BASE_SHA + DIFF_PATH + scope-cap events
scripts/argus-classify-diff.sh /tmp/argus-T001-diff.txt             # JSON diff signals for selective rule loading
scripts/argus-select-rules.sh '{"touches_swiftui":true}' argus/rules # JSON load/skipped rule-pack lists
scripts/argus-run-tests.sh T001 MyScheme MyTests                    # xcodebuild + test-slot mgmt; exit 0 green, 3 red
scripts/argus-verify-tdd.sh T001 /path main MyScheme MyTests        # red→green verify; exit 0 ok, 2 flag, 3 block
scripts/argus-emit-verdict.sh T001 approved '[]' --task-uuid <uuid> # YAML verdict + back-ref + event + stdout line
scripts/emit-agent-session-completed.sh argus review T001 auto:T001 --verdict approved   # shared session-close (any agent); auto: resolves start-ts from emit-agent-boot stamp

# Chanakya inbox sweep — mechanical extractions from modes/inbox-sweep.md (Phase 2.6.5):
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

# Chanakya test-manifest + test-flow — extractions from modes/tests.md (Phase 2.6.5):
scripts/tests-dirty-state-check.sh <path>               # exit 2 if user-testing.md has checked boxes or Notes
scripts/tests-scan-candidates.sh                        # enumerate merged + user-verifying tasks
scripts/tests-pull-cases.sh <task-id>                   # YAML `cases:` block from debrief YAML; historical sidecar import fallback
scripts/tests-write-manifest.sh [--force]               # stdin YAML → plans/user-testing.md
scripts/tests-write-round.sh <N> <scope> <tasks-csv> <body-file>   # round artifact via lib-ledger write_round_artifact
scripts/tests-promote-round.sh <N>                      # gate-check + pre-checked manifest; exit 3 on gate fail
scripts/tests-diff-rounds.sh <A> <B>                    # markdown diff between rounds

# Achilles task mode — mechanical extractions from modes/task.md (Phase 2.6.5):
eval "$(scripts/task-load-spec.sh T001)"                # TASK_MODE/BRIEF_PATH/SIZE/TYPE/ACCEPTANCE_JSON
scripts/task-build-debt-gate.sh [--override]            # exit 2 if blocked; emits build_debt_blocked
scripts/task-claim.sh <task-uuid> <brief-uuid> <size>   # task + brief state transitions
eval "$(scripts/task-worktree-setup.sh T001 /repo)"     # PROJECT/ORIG_BRANCH/ORIG_HEAD/WORKTREE
scripts/task-build-gate.sh lsp-only T001 /wt MyScheme "platform=iOS Simulator" [zaps-app/Turnip.xcodeproj] # xcodebuild + lock; 6th arg pins -project/-workspace in multi-project repos (#238); exit 4 = duplicate-invocation refused (#209)
scripts/studio-tf-push.sh push [--version X.Y.Z]        # TestFlight push driver; explicit version override + rejected-version preflight
scripts/node-parity.sh [--fix|--dry-run]                # probe + cache toolchain versions; optionally install missing brew packages and print manual Xcode/runtime fixes (#126/#131)
scripts/check-xcode-parity.sh m1mini                    # pre-dispatch guard; exit 1 = MAJOR Xcode drift; STUDIO_IGNORE_XCODE_DRIFT=1 overrides (#136)
scripts/node-warmup.sh m1mini [project]                 # async-safe pre-dispatch source sync + package cache warm-up (#138)
scripts/task-write-test-cases.sh T001 '[{...}]'         # stdout debrief `tests.added` payload; no standalone sidecar write
scripts/task-invoke-argus.sh T001 /wt main S            # emits review_requested with reviewed base SHA (Argus invoked via Agent tool)
scripts/task-merge.sh T001 /wt feature-branch --require-approved  # merge lock + approved-only policy + post-review base re-check
scripts/node-janitor.sh [--days N] [--dry-run]          # periodic node-side sweep of stale derived-data + worktrees + dispatch logs/registry (#129, #272); LaunchAgent-driven
scripts/install-node-janitor-launchagent.sh             # render + load every-6h LaunchAgent on the local node (auto-run by bootstrap --worker)
scripts/monitor-install.sh install                      # opt-in laptop LaunchAgent; hourly node-health monitor + notifications for >6h unreachable nodes (#132)
scripts/node-monitor.sh                                 # one-shot monitor check; tracks streak/cooldown state and emits node_unreachable alerts (#132)
scripts/task-emit-debrief.sh <task-uuid> <brief-uuid> self-reviewed '{...}'   # YAML debrief + state flips

# Studio-feedback ingestion (auto-fires via SessionStart hook + Chanakya Step 0F):
scripts/ingest-feedback.sh                              # idempotent; silent no-op outside generic-dev-studio

# Studio PR autopilot primitives (#318):
scripts/pr-reviewer-eligibility.sh codex-reviewer       # no-prompt/no-secret reviewer preflight + real verdict-emitting smoke gate
scripts/pr-reviewer-eligibility.sh claude-reviewer      # same reviewer floor for Claude Code; uses CLAUDE_REVIEWER_HOME + CLAUDE_REVIEWER_CONFIG_DIR
scripts/phase-review.sh --review-host claude-reviewer --input phase-plan.md --output review.md   # sibling-host phase gate; emits PHASE_REVIEW_VERDICT=clean|blocked|ambiguous
scripts/pre-commit-review.sh                            # manual reviewer gate for risky staged diffs; accepts approved/approved_with_fixes only
scripts/lint-field-review-surfaces.sh --staged          # blocks raw cross-host review snippets outside phase-review wrappers
scripts/lint-project-skill-links.sh [--host codex]      # repo-local project skill discovery link invariant + repair helper
scripts/pr-headless-review.sh <pr>                      # run smoke-eligible reviewer, post gate with cross-host/fallback metadata, merge if non-blocked
scripts/pr-headless-review.sh <pr> --no-require-cross-host  # opt out of default independent-provider reviewer policy for explicit non-safety-floor runs
scripts/pr-autopilot.sh <pr> --verdict approved         # post reviewer gate, then merge if non-blocked
scripts/pr-merge-finalize.sh <pr> --method auto         # <4 commits=rebase, larger main=merge commit, then fetch/prune
scripts/resolve-reviewer-model.sh --review-host codex-reviewer --implementation-host claude-code  # policy-backed reviewer model/profile resolver
scripts/check-model-catalog.sh --print-refresh-checklist # validate model catalog + print official-doc refresh checklist
scripts/recommend-model.sh --size s --kind impl --cross-file-count 3 --novelty-score 1

# Chanakya sweep-time detections (Step 0E3, auto-invoked by Chanakya):
scripts/detect-edits.sh --quiet                         # emits brief_edited + debrief_edited

# App Store submission watcher (Chanakya Step 0B3, auto-invoked by every sweep):
scripts/appstore-watch.sh                               # idempotent; self-gated on marker.next_check_at
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
| `NODE_BUILD_TIMEOUT` | `1800` (30m) | Max remote build/test command stream per `node-dispatch.sh`; needs `gtimeout` or `timeout`, otherwise the script warns and runs unbounded. |
| `NODE_DISPATCH_TAIL_LINES` | `40` | Remote log lines printed when the detached node runner finishes but its `.exit` marker is missing. |
| `NODE_ARTIFACT_RETRIEVE` | `0` | Set to `1` to pull remote `.xcarchive` / `.xcresult` directories from the node's DerivedData back to the matching local DerivedData after a successful remote Xcode build/test. |
| `NODE_SOURCE_SYNC_MODE` | `auto` | Remote source sync mode: `auto` does one full rsync per session/path, then git-diff selective rsync; `full` and `selective` force either path. |
| `NODE_SOURCE_SYNC_SMOKE` | `0` | Set to `1` to dry-run compare selective sync against a full rsync and fall back to full when they diverge. |
| `NODE_WARMUP_TIMEOUT` | `900` (15m) | Max async node warm-up command stream. The first remote gate invocation per session/node launches warm-up in the background and continues. |
| `ACHILLES_UNATTENDED` | `0` | Set to `1` to pass `--dangerously-skip-permissions` for fully unattended overnight runs. |
| `ACHILLES_AUTONOMOUS` | `0` (set to `1` automatically by the worker per task) | Tells the Achilles subagent there is no user to answer clarifying questions; it must pick obvious defaults and document them in the debrief. Exported by `achilles-worker.sh` for every `claude -p` subprocess. Do not set manually unless testing. |
| `ACHILLES_DISPLAY_NAME` | derived (see below) | Friendly name for panes / logs. Override per-shell, or pre-bake per-project via `~/.dev-studio/<project>/.display_name` (first non-comment line wins). |

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
