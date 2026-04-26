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

**Stuck-state detection:** if `claude -p` exits `rc=0` but no debrief was written at `~/.dev-studio/<project>/plans/chanakya-inbox/<task-id>-debrief.md`, the worker treats the task as silently stuck (the subagent almost certainly exited after asking a clarifying question the one-shot process could never answer). The task file goes to `rescue/` and a sidecar `<task-id>-stuck.md` captures the flags, timestamp, and last 200 lines of log. Operator decides whether to re-brief and re-dispatch.

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
scripts/argus-run-tests.sh T001 MyScheme MyTests                    # xcodebuild + test-slot mgmt; exit 0 green, 3 red
scripts/argus-verify-tdd.sh T001 /path main MyScheme MyTests        # red→green verify; exit 0 ok, 2 flag, 3 block
scripts/argus-emit-verdict.sh T001 approved '[]' --task-uuid <uuid> # YAML + legacy md + back-ref + verdict event + stdout line
scripts/emit-agent-session-completed.sh argus review T001 auto:T001 --verdict approved   # shared session-close (any agent); auto: resolves start-ts from emit-agent-boot stamp

# Chanakya inbox sweep — mechanical extractions from modes/inbox-sweep.md (Phase 2.6.5):
scripts/sweep-enumerate-debriefs.sh                     # classify inbox debriefs → task-debrief/build-check/release/direct-debrief
scripts/sweep-ingest.sh debrief <path> [--argus-exempt] # Step 0A — task + direct-debrief ingest (follow-ups, back-refs, state flip)
scripts/sweep-ingest.sh build-check <path>              # Step 0B — debt counter reset/hold, TBUILD auto-file on red
scripts/sweep-ingest.sh release <path>                  # Step 0B2 — release artifact + per-task release back-ref
scripts/sweep-threshold-actions.sh                      # Step 0C — warn@6 files TBUILD, block@12 sets state flag
scripts/sweep-janitor.sh all                            # Step 0D — worktrees/feedback-assets/orphans/scaling-alerts (honors DRY_RUN)
scripts/sweep-process-events.sh                         # Step 0E — event fan-out (drain / push-queue / follow-ups / drift log)
scripts/sweep-feedback-reminders.sh                     # Step 0E2 — emits feedback_reminder_due for past-due rows
scripts/sweep-adaptive-backoff.sh 1                     # Step 0G — 900→1800→3600→7200 on blank; reset 900 on activity
scripts/push-queue.sh append --kind review_blocked --task T001 --text "..."   # used by sweep + argus

# Chanakya test-manifest + test-flow — extractions from modes/tests.md (Phase 2.6.5):
scripts/tests-dirty-state-check.sh <path>               # exit 2 if user-testing.md has checked boxes or Notes
scripts/tests-scan-candidates.sh                        # enumerate merged + user-verifying tasks
scripts/tests-pull-cases.sh <task-id>                   # YAML `cases:` block from debrief (YAML + legacy fallback)
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
scripts/task-write-test-cases.sh T001 '[{...}]'         # twin-write standalone + stdout YAML
scripts/task-invoke-argus.sh T001 /wt main S            # emits review_requested (Argus invoked via Agent tool)
scripts/task-merge.sh T001 /wt feature-branch           # merge lock + merge + worktree remove + DerivedData clean
scripts/task-emit-debrief.sh <task-uuid> <brief-uuid> self-reviewed '{...}'   # YAML + legacy md + state flips

# Studio-feedback ingestion (auto-fires via SessionStart hook + Chanakya Step 0F):
scripts/ingest-feedback.sh                              # idempotent; silent no-op outside generic-dev-studio

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
