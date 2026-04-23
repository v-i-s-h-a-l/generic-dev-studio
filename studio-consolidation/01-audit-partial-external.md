# 01-audit, partial — External state (git / scripts / issues / memory)

**Source:** Session B Explore agent (id `a04cb292`), completed 2026-04-24.
**Scope:** git log recent, scripts inventory, GitHub issues, memory entries, recent debriefs/feedback. Pure inventory.

---

## A. Git History Signals

### Recent-work themes (last ~2 weeks)

**Theme 1: Phase 2.6.5 prose extraction + event-log hardening** (11 commits, 2026-04-17 to 2026-04-22)
- Refactor procedural prose into standalone shell scripts + fix pre-2.6 event-log double-emission.
- Key landings: `5bbd5be` (Phase 2.6.5 dual-write-transition pattern + dual_write_partial event), `5470476` (lib-ledger.sh spine + write-event.sh + fixture scaffold).
- Ledger mutation primitives now owned by scripts, not prose; event-emission contract formalized at `_shared/contracts/event-emission.md`.

**Theme 2: Phase 2.6.6 event contract + review-waive lifecycle** (7 commits, 2026-04-23)
- Issues closed: #83, #84, #85, #86, #87.
- Key landings: `2b2a34c` (structured review-waive lifecycle + SessionStart surface), `ae9b980` (session-start stamp drives duration_s), `19678fc` (debrief_emitted synthetic direct:<uuid> task id).
- New scripts: `waive-start.sh`, `waive-lift.sh`, `emit-agent-boot.sh`, `emit-agent-session-completed.sh`.

**Theme 3: Sweep reliability + base-branch auto-refresh** (4 commits, 2026-04-23)
- Issues closed: #91, #92.
- Key landings: `190ffe9` (sweep reliability bundle), `f8e010c` (Achilles pre-review base-branch auto-refresh, Step 8.4).
- New scripts: `scripts/backfill-orphan-debriefs.sh` (205 lines), `scripts/achilles-refresh-base.sh` (108 lines).
- Trigger: 3 tasks (T302, T305, T323) staying invisible in master plan.

**Theme 4: Router dispatch fixtures** (skill-testing primitive, 1 commit 2026-04-24)
- `0610ac1` (Phase 2.6.5 live-fire: router dispatch fixtures).
- `tests/mode-packs/{chanakya,achilles,argus}/SKILL.yaml` (117 lines, 9 fixtures).

**Theme 5: Consolidation arc launch** (1 commit, 2026-04-24)
- `482b8d6` (Session A exit — 7-session arc plan + proxy-user persona, 168 lines at `studio-consolidation/00-plan.md`).

### File churn (last 20 commits)

Top mutated files:
- `_shared/contracts/events.md` (6 commits) — 4 new event types: base_refreshed, base_refresh_conflict, inbox_sweep_completed, debrief_backfilled
- `achilles/modes/task.md` (4 commits) — Steps 8.4 + 8.5 + 11
- `scripts/lib-ledger.sh` (4 commits)
- `scripts/emit-agent-session-completed.sh` (3 commits)
- `chanakya/modes/inbox-sweep.md` (2 commits)
- `scripts/lib-paths.sh` (4 commits)
- `REVIEW.md` (2 commits) — R10 framing #82, R11 rule #89
- `README.md` (5 commits) — v0.4.0 timeline

---

## B. Scripts Inventory (70 scripts)

### By purpose cluster

**Core dispatch & worker control:**
`achilles-dispatch.sh`, `achilles-queue.sh`, `achilles-worker.sh`, `achilles-cancel.sh`, `push-queue.sh`, `worker-status.sh`

**Event emission & ledger:**
`write-event.sh`, `emit-agent-boot.sh`, `emit-agent-session-completed.sh`, `lib-ledger.sh`, `task-emit-debrief.sh`, `ingest-feedback.sh`, `backfill-orphan-debriefs.sh`

**Reading & analysis:**
`read-events.sh`, `read-shared.sh`, `analyze-collect.sh`, `budget-report.sh`, `status-load-snapshots.sh`, `status-fallback-loaders.sh`, `status-domain.sh`, `status-render-tasks.sh`, `detect-edits.sh`, `migration-ledger.sh`

**Argus pipeline:**
`argus-setup.sh`, `argus-diff-extract.sh`, `argus-run-tests.sh`, `argus-verify-tdd.sh`, `argus-emit-verdict.sh`, `task-invoke-argus.sh`

**Achilles pipeline steps:**
`task-load-spec.sh`, `task-build-debt-gate.sh`, `task-claim.sh`, `task-worktree-setup.sh`, `task-build-gate.sh`, `task-write-test-cases.sh`, `task-merge.sh`, `achilles-refresh-base.sh`

**Chanakya sweep & intake:**
`sweep-enumerate-debriefs.sh`, `sweep-ingest.sh`, `sweep-process-events.sh`, `sweep-feedback-reminders.sh`, `sweep-janitor.sh`, `sweep-threshold-actions.sh`, `sweep-adaptive-backoff.sh`

**Artifact generation & validation:**
`capability-manifest.sh`, `rebuild-index.sh`, `update-surface-manifest.sh`, `lint-architecture.sh`, `validate-schema.sh`, `verify-ledger.sh`

**Test & release infrastructure:**
`tests-scan-candidates.sh`, `tests-pull-cases.sh`, `tests-write-manifest.sh`, `tests-diff-rounds.sh`, `tests-promote-round.sh`, `tests-dirty-state-check.sh`, `test-mode-pack.sh`, `graduation-scan.sh`

**Waive system (Phase 2.6.6):**
`waive-start.sh`, `waive-lift.sh`

**Other:**
`next-task-id.sh`, `chanakya-snap.sh`, `chanakya-snap-prewarm.sh`, `feedback-retroactive-sweep.sh`, `fleet-cleanup.sh`, `machine-id.sh`, `appstore-watch.sh`, `query-plans.sh`, `scaffold-agent.sh`, `sync-shared-remote.sh`, `lib-fixtures.sh`, `lib-paths.sh`

### Event emission inventory

31 scripts call `emit_event`, `append_event`, or `write-event.sh`. 30+ event types registered in `_shared/contracts/events.md` (agent_boot, agent_session_completed, brief_*, task_*, debrief_emitted, review_*, orphan_debriefs_backfilled, inbox_sweep_completed, base_refreshed, base_refresh_conflict, feedback_ingested, dual_write_partial, etc.).

### Host-interface & dispatch scripts (relevant to #88)

- `achilles-dispatch.sh` — queues task + selects worker slot; no host awareness yet
- `achilles-worker.sh` — subprocess spawn via `claude -p`
- `task-invoke-argus.sh` — currently emits event only; does NOT spawn Argus (keystone for planned `dispatch-review.sh`)
- **No scripts currently hardcode Claude-Code-specific primitives** (Agent/Read/Write tool references are in prose files only: `achilles/modes/task.md`, `argus/modes/code-quality.md`)

### Path resolver usage

All scripts that read/write `~/.dev-studio/**` paths source `scripts/lib-paths.sh` and call resolver functions. **No hardcoded paths detected in scripts.** Iron Law #3 compliant.

Resolvers: `resolve_event_log`, `resolve_ledger_path`, `resolve_waive_dir`, `resolve_waive_file`, `resolve_session_start_stamp`, `resolve_shared_root`, `resolve_project_root`, + others (11+ total).

---

## C. GitHub Issues (19 open)

### Open issues

| # | Title | Labels | Type |
|---|-------|--------|------|
| **94** | 20260420-queued-prompt-slack-while-building | enhancement, theme/internal | Workflow: background builds while drafting Slack posts |
| **93** | 20260423-200000-rule-gap-parenthesized-studio-feedback-not-recognized | enhancement, theme/internal | Parser: parenthesized studio-feedback syntax missed |
| **90** | 20260423-120615-note-playwright-mcp-authenticated | enhancement, theme/internal | Note: Playwright MCP requires OAuth |
| **89** | 20260422-062245-rule-gap-never-push-main-to-remote | enhancement, theme/internal | Codified as R11 in REVIEW.md |
| **88** | Host-Agnostic Workers v1 (Achilles + Argus) | enhancement, roadmap, theme/internal | **MAJOR** — spec complete; 1 research comment 2026-04-24 |
| **76** | Audit mode-pack dual-write during Phase 2.6 transition | bug, theme/internal, phase-2-6-followup | Drift found T218a legacy+YAML |
| **75** | 20260420T003703Z-skill-appstore-whats-new-too-long | enhancement, theme/internal | App Store metadata char limit |
| **74** | 20260420-013850-enhancement-bug-analysis-slack-flow | enhancement, theme/internal | Slack alerting integration |
| **73** | 20260420T004200Z-skill-appstore-missing-pr-step | enhancement, theme/internal | App Store submission missing PR verify |
| **65** | Task-level model recommendation system | enhancement, roadmap, theme/internal | Suggest Opus/Sonnet/Haiku per task |
| **62** | Dashboard reads over new ledger schemas | roadmap, theme/observe, phase-2-6-followup | Phase 6 prerequisite |
| **61** | Opportunistic ledger migration for other projects | enhancement, theme/internal, phase-2-6-followup | Multi-project migration tooling |
| **58** | Processed-brief archive forward-port decision | enhancement, theme/internal, phase-2-6-followup | Legacy archive migration |
| **57** | Move project-specific config out of _shared/primitives/ | polish, theme/internal, phase-2-5-followup | Project config scope |
| **56** | First tier-3 consumer mode pack | enhancement, theme/internal, phase-2-5-followup | Multi-machine-sync consumer |
| **55** | LAN / rsync sync as same-LAN optimization | enhancement, theme/internal, phase-2-5-followup | Same-LAN hosts optimization |
| **64** | Per-artifact CHANGELOG files if schema drift grows | polish, theme/internal, phase-2-6-followup | Schema history docs |

### Open-issue themes

- **Host-agnostic / portability:** #88 (major, spec complete), #56 (tier-3 consumer), #57 (shared/primitives scope).
- **Phase 2.6 post-cutover:** #76, #62, #61, #58, #64.
- **Phase 2.5 follow-ups:** #57, #55, #56.
- **Consolidation / studio gaps:** #93, #90, #89, #94, #74, #73, #75, #65.

---

## D. Memory Entries (18 files)

### Inventory

| File | Type | Last mod | Key claim | Staleness |
|------|------|---------|-----------|-----------|
| **MEMORY.md** | index | 04-24 02:17 | 17 entries | **CURRENT** |
| project_consolidation_arc.md | project | 04-24 02:17 | Session A done; B in flight | **CURRENT** |
| project_host_agnostic_workers.md | project | 04-23 17:18 | Audit done, OSS research complete, issue #88 filed | **CURRENT** |
| project_planning_sweep_pending.md | project | 04-23 17:18 | "Phase 2.6.5 COMPLETE; next: live-fire validation" | **STALE** — live-fire + sweep reliability shipped 04-24; superseded by consolidation arc |
| feedback_world_class_standard.md | feedback | 04-20 | Never mediocre | Valid |
| feedback_no_manual_input.md | feedback | 04-20 | Permission prompts block | Valid |
| feedback_artifact_paths.md | feedback | 04-20 | All writes to ~/.dev-studio/** | Valid |
| feedback_docs_sync_routine.md | feedback | 04-18 | Auto-sync docs.html + README | Valid |
| feedback_review_before_commit.md | feedback | 04-18 | Walk REVIEW.md before commit | Valid |
| feedback_todo_avoidance.md | feedback | 04-22 | No casual TODOs | Valid |
| feedback_max_plan_pricing.md | feedback | 04-22 | Claude Max; no per-token cost | Valid |
| project_architecture.md | project | 04-18 | Per-project runtime | Load-bearing |
| project_mac_mini_worker.md | project | 04-20 | M1 Mac mini for builds | Valid |
| project_mac_studio_plan.md | project | 04-22 | Office deployment ~May 2026 | Valid |
| project_phase_6_deferred.md | project | 04-22 | Phase 6 to end; order 2.5→2.6→2.7→3→4→5→7→8→9→6 | Valid |
| project_debrief_backlog_provenance.md | project | 04-18 | Pre-04-17 debriefs predate event-log | Valid |
| reference_claude_dirs_maintenance.md | reference | 04-20 | LaunchAgent mirrors ~/.claude | Valid |
| reference_review_guide.md | reference | 04-18 | REVIEW.md is rulebook | Valid (now R10, R11) |

### Stale candidates

**`project_planning_sweep_pending.md`** — "next: Phase 2.7" superseded by consolidation arc's Session D. Safe to archive or update to point at arc.

---

## E. Recent Debriefs & Feedback

**Debriefs** (`~/.dev-studio/turnip-ios/plans/debriefs/`, 6 visible): T306, T302, T305, T300, T277, T323. All post-2026-04-17 (event-log era).

**Feedback:** No `~/.dev-studio/turnip-ios/plans/feedback/` directory exists.

**Studio feedback:** Retroactive-sweep agent surfaced 8 issues in last 3 days (→ issues #93, #94, #90, #75, #74, #73 + 2 earlier). Pattern: user queues prompts during long builds; some never submit (#94). Parser edge case: parenthesized feedback not recognized (#93).

---

## Summary

- **70 scripts** operational; 31 emit structured events; Iron Law #3 compliant (lib-paths.sh everywhere).
- **19 open issues** clustered around host-agnostic portability (#88 major), Phase 2.6 post-cutover refinement, studio capability gaps.
- **Recent 2 weeks:** 4 major phases completed (2.6 stability, 2.6.6 contract, reliability, skill-testing fixtures); 1 arc plan launched.
- **Memory state:** 1 entry stale (`project_planning_sweep_pending.md`); rest current or load-bearing.
- **#88 is the critical unblocked item**: spec complete post revision, implementation pending the consolidation arc's Session D synthesis.
