---
name: dev-studio
description: Studio v2 umbrella router for canonical roles. Routes `/dev-studio` invocations and documents post-A10 compatibility aliases for former top-level agent names.
type: agent-router
schema_version: 1
version: 0.1.0
---

# dev-studio — Studio v2 Router

`/dev-studio` routes by canonical role. Role contracts live in `core/v2/roles`; aliases live in `core/v2/registry/roles.json` and `forwarders.yaml`. The v1 router surfaces are deleted after A10.

<!-- v2-dev-studio:scope -->
## Scope

The router selects the role contract only. Mode procedure, authority checks, handoffs, events, project profiles, and checkpoint storage stay in their owning contracts.

`/dev-studio` is the primary traffic surface for v2 role routing.

<!-- v2-dev-studio:dispatch -->
## Dispatch table

Canonical roles: `manager`, `worker`, `reviewer`, `perf`, `planner`, `qa-engineer`, `flow-tester`, `release-manager`, `host-adapter`, `operator`. Compatibility aliases resolve through `scripts/v2-role-resolve.sh`.

Role help: bare `help` shows the router-level role index unless a session-local active role is already clear; `<role> help` shows that role's commands, examples, aliases, and shared lifecycle actions. The active role is only host conversation context, not on-disk state.

<!-- v2-dev-studio:lifecycle -->
## Lifecycle Actions

`checkpoint` and `resume-checkpoint` route through the selected role. Bare `/dev-studio checkpoint` invocations land in `manager`; role-qualified invocations such as `/dev-studio <role> checkpoint` are owned by that role. Create/update checkpoint commands print the checkpoint id, and that id is enough for `resume-checkpoint`. Checkpoints do not replace summaries, verdicts, release packets, QA/flow checklists, perf verdicts, or event logs.

<!-- v2-dev-studio:manager-context-header -->
## Manager Context Header

All `/dev-studio manager …` surface invocations render the manager context header before any side effect or further prompt. Hosts source `scripts/lib-manager-context-header.sh` and emit either `manager_context_header_emit_text <repo-root>` (default human-readable) or `manager_context_header_emit_json <repo-root>` (machine-readable). The header carries the project, current branch, dirty flag, resolved `base_ref`/`base_sha`, the `on_protected_base` flag, and the project's branch-policy fields (`default_base`, `release_branch_pattern`, `merge_target_to_main`, `allow_feature_off_feature`) sourced from `~/.dev-studio/<project>/config/features.env` (override: `STUDIO_FEATURE_CONFIG_FILE`).

The header is informational; it does not gate or mutate. Surface enforcement still lives in the pre-commit base-branch guard and the `pr-merge-finalize` merge-target gate (`_shared/standards/branch-discipline.md`). Manager ingest reuses the same primitive as an explicit source-branch pre-flight: `scripts/dev-studio-ingest-resolve.sh` embeds the header under `manager_context_header` and a `source_branch_preflight` block in its JSON output, and the host surfaces both before any ingest write. `--scope studio`, `--scope project`, and `--to <project-slug>` remain the documented non-interactive override surface.

<!-- v2-dev-studio:manager-analyze -->
## Manager Analyze Routing

`/dev-studio manager analyze` must call `scripts/manager-analyze.sh --cwd <current-project-root>`. It runs only from a `generic-dev-studio` checkout and owns studio-side telemetry/log analysis plus feedback triage. Project report syncing must use `/dev-studio manager reconcile`, which calls `scripts/manager-reconcile.sh --cwd <current-project-root>`.

Studio-feedback records still search issues first, consolidate covered work, create only distinct issues, and move to `processed/` only after a destination exists. Unsafe public records stay in the inbox with a policy reason.

`(studio-feedback)` and `(studio feedback)` tags create sidecar records under the studio feedback inbox and do not replace the rest of the prompt.

Studio-feedback tag detection keeps both anchored forms available to hosts: `^\(studio[-\s]feedback\)` and `\(studio[-\s]feedback\)\s*$`. After capture, continue answering any non-feedback part of the prompt.

<!-- v2-dev-studio:release-configure -->
## Release Manager Configure

`/dev-studio release-manager configure` routes to the release-manager role and uses `scripts/release-manager-configure.sh` for project-scoped Slack release notification setup. Defaults stay editable and avoid TestFlight `<!here>`.

<!-- v2-dev-studio:manager-chain-monitor -->
## Manager Chain Monitor

`/dev-studio manager chain-monitor` routes to the manager role and uses `scripts/manager-chain-monitor.sh` for chain monitor `configure`, `sync`, `status`, and `recovery`. `status` is non-mutating and reports owner home, owner project, active and archived state paths, Slack List IDs, dry-run collision count, and pending write counts without secrets. Recovery defaults to dry-run; destructive full-rewrite execution must require explicit operator approval. Background sync scheduling uses `scripts/schedule-chain-monitor.sh` and is macOS LaunchAgent only, with login-home ownership.

<!-- v2-dev-studio:manager-config -->
## Manager Config

`/dev-studio manager config` routes to the manager role and uses `scripts/manager-feature-config.sh` for project-scoped feature configuration. It supports `list`, `get`, `enable`, `disable`, `set`, and `doctor`; settings live under `~/.dev-studio/<project>/config/` and secrets remain in the existing project-scoped secrets locations.

<!-- v2-dev-studio:manager-branch -->
## Manager Branch

`/dev-studio manager branch` routes to the manager role and uses `scripts/manager-release-branch.sh` for release branch status, prepare, sync, and PR preflight. It is non-mutating by default, creates remote release branches only with explicit execution flags, and refuses PR handoff when the target branch is missing or mergeability checks find conflicts. Release readiness, tags, TestFlight, App Store, and public release messages remain release-manager responsibilities.

<!-- v2-dev-studio:landing -->
## Bare Role Landing

Bare role invocations start a lightweight landing. Load the role contract, inspect cheap cwd/profile context, suggest likely next moves, then report the direct invocation once the workflow is selected. `manager ingest` calls `scripts/dev-studio-ingest-resolve.sh`; `manager analyze` calls `scripts/manager-analyze.sh`; `manager reconcile` calls `scripts/manager-reconcile.sh`; `manager plan-chain` calls `scripts/manager-plan-chain.sh`; `manager composite-chain` calls `scripts/manager-composite-chain.sh`; `manager work-chain` calls `scripts/manager-work-chain.sh`; `manager chain-monitor` calls `scripts/manager-chain-monitor.sh`; `manager config` calls `scripts/manager-feature-config.sh`; `manager branch` calls `scripts/manager-release-branch.sh`. Bare `scripts/studio-chain-runner.sh` shows runnable chains, resumable runs, and next actions. Prefer `/dev-studio manager work-chain ...` in user-facing guidance; script commands are secondary automation/debug equivalents. Use `manager plan-chain <goal-or-issue>` when the source still needs planner artifact, phase-review, durable issue creation, native parent/sub-issue structure, Project field population, and manifest generation; add `--include-comments` with `--issue <n>` or `--issue-set <csv>` when the planner must use the public-safe issue-context packet and record packet/sidecar artifacts. Comment-aware planning is for public comment decisions, constraints, failures, acceptance changes, conflicts, and open questions; comments inform the reviewed plan but never override issue bodies, manifests, state files, event logs, reviewed plan artifacts, or worker summaries. Add `--execute` for one-command unattended launch and `--interactive` for attended execution. Use `manager composite-chain init --manifest <path>` as the selected MVP equivalent to `work-chain --composite-manifest <file>` for explicit composite manifests; it initializes private runtime state without planning or running child chains. Use `manager composite-chain status --run-id <id>` or `--state <path>` for a validated, non-mutating composite progress recap and next clean-session command. Use `manager composite-chain plan-active-child --run-id <id>`, `manager composite-chain execute-active-child --run-id <id>`, and `manager composite-chain resume --run-id <id>` only as the status output directs; issue-sourced children are planned with the public-safe issue-context packet, while manifest-sourced children keep source-file planning. Each step preserves plan review, issue creation, worker execution, verification, PR review/merge policy, and closeout gates. Sequential composite mode plans a later child only after prior children are completed or skipped. Parent-issue natural-language extraction and `work-chain --composite-parent <issue>` are future/non-MVP and must not be promised. Use `manager work-chain --from-plan <task-graph|planner-output>` to route an existing planner artifact through the same orchestration and then launch the generated chain unattended by default; add `--plan-only` to stop after manifest creation. Use `--discover <manifest|chain-name|chain-id>` for filtered discovery; chain IDs are exact selectors too. Use `--doctor <run_id>` for a read-only recovery recommendation over stale reports, active halts, retry cooldowns, checkpoint drift, and phase-review status. `/dev-studio manager work-chain ios-v2-execution` auto-runs that chain while bare `manager work-chain` lands in discovery. Chain execution supports `--attended` and `--unattended`; end attended/ingest work-chain planning with the next `/dev-studio manager work-chain ...` command.

After a bare role landing, later bare subcommands may resolve through that active role when unambiguous in the same session. Store the resolved canonical role after alias resolution. Explicit `/dev-studio <role> ...` always wins and replaces the active role for that invocation; bare `/dev-studio` re-lands in manager and clears any assumed active-role shortcut. Ambiguous commands require the role prefix or a lightweight clarification.

After workflow selection, report the direct one-line invocation the user can run next time.

<!-- v2-dev-studio:verified-resume -->
## Attended Verified Resume

Attended chain runs may pause for explicit human verification. The pause
writes a typed halt with `reason_id: attended_verification_pending`
(`_shared/contracts/chain-halt-record.schema.json`) and surfaces a single
verified-resume command of the form
`/dev-studio manager work-chain --resume <run_id> --verified --yes`. The
manager routes that invocation to `scripts/manager-work-chain.sh`, which
inspects the canonical verified resume closeout inventory documented in
`_shared/contracts/completion-summary.md` §Verified Resume Closeout and runs
each finish step idempotently (test/build evidence, worker summary, commit,
push, PR, review, merge, issue closure, local main sync, worktree cleanup,
DerivedData and stale-artifact cleanup, and report regeneration). Unsafe or
user-sensitive steps stay gated by the existing ask-first and retention
rules; `--verified --yes` does not widen approval authority.

<!-- v2-dev-studio:chain-recap -->
## Durable Chain Progress Recap

Chain sessions emit a stable user-facing progress packet at three durable
boundaries: before execution starts (chain goal, ordered tasks, dependency
edges, parallel opportunities, expected human checkpoints, and the next
command), after every completed task (previous task, just completed task,
what changed, verification evidence summary, next task or command, overall
progress, and the current chain direction or goal), and on pause, halt, or
finish (what remains and the exact verified-resume or recovery command).
The recap is generated from durable run state — chain manifests, event-log
projections, worker summaries, and halt records — never from ephemeral
assistant memory, and it does not expose private telemetry payloads,
secrets, or raw operator prompts. See
`_shared/contracts/completion-summary.md` §Durable Chain Progress Recap for
the field-level contract.

<!-- v2-dev-studio:intent -->
## Intent detection

Priority: explicit canonical role, compatibility alias, former top-level name, session-local active-role command when unambiguous, bare role landing, then manager landing. Unknown role tokens fail before side effects.

<!-- v2-dev-studio:forwarders -->
## Forwarders

Compatibility alias state is data in `forwarders.yaml`. Post-A10, `forwarders: []` is expected. Aliases do not add business logic, bypass role contracts, or widen permissions.
