---
name: dev-studio
description: Studio v2 umbrella router for canonical roles. Routes `/dev-studio` invocations and documents post-A10 compatibility aliases for former top-level agent names.
type: agent-router
schema_version: 1
version: 0.1.0
---

# dev-studio — Studio v2 Router

`/dev-studio` routes by canonical role. Role contracts live in `core/v2/roles`;
aliases live in `core/v2/registry/roles.json` and `forwarders.yaml`. The v1
router surfaces are deleted after A10.

<!-- v2-dev-studio:scope -->
## Scope

The router selects the role contract only. Mode procedure, authority checks,
handoffs, events, project profiles, and checkpoint storage stay in their owning
contracts.

<!-- v2-dev-studio:dispatch -->
## Dispatch table

Canonical roles: `manager`, `worker`, `reviewer`, `perf`, `planner`,
`qa-engineer`, `flow-tester`, `release-manager`, `host-adapter`, `operator`.
Compatibility aliases resolve through `scripts/v2-role-resolve.sh`.

Role help: bare `help` shows the router-level role index unless a session-local
active role is already clear; `<role> help` shows that role's commands,
examples, aliases, and shared lifecycle actions. The active role is only host
conversation context, not on-disk state.

<!-- v2-dev-studio:lifecycle -->
## Lifecycle Actions

`checkpoint` and `resume-checkpoint` route through the selected role. Bare
checkpoint invocations land in `manager`; role-qualified invocations are owned
by that role. Checkpoints do not replace summaries, verdicts, release packets,
QA/flow checklists, perf verdicts, or event logs.

<!-- v2-dev-studio:manager-analyze -->
## Manager Analyze Routing

`/dev-studio manager analyze` must call
`scripts/manager-analyze.sh --cwd <current-project-root>`. It runs only from a
`generic-dev-studio` checkout and owns studio-side telemetry/log analysis plus
feedback triage. Project report syncing must use `/dev-studio manager
reconcile`, which calls `scripts/manager-reconcile.sh --cwd
<current-project-root>`.

Studio-feedback records still search issues first, consolidate covered work,
create only distinct issues, and move to `processed/` only after a destination
exists. Unsafe public records stay in the inbox with a policy reason.

`(studio-feedback)` and `(studio feedback)` tags create sidecar records under
the studio feedback inbox and do not replace the rest of the prompt.

<!-- v2-dev-studio:release-configure -->
## Release Manager Configure

`/dev-studio release-manager configure` routes to the release-manager role and
uses `scripts/release-manager-configure.sh` for project-scoped release
notification setup. Slack is the first supported integration. Quick setup writes
defaults the user can change later: TestFlight uses no `<!here>` by default,
a brief parent message, threaded tester details, module grouping when useful,
and technical notes at the end only when they affect testing. App Store release
announcements remain optional and post to the configured releases channel when
present.

<!-- v2-dev-studio:landing -->
## Bare Role Landing

Bare role invocations start a lightweight landing. Load the role contract,
inspect cheap cwd/profile context, suggest likely next moves, then report the
direct invocation once the workflow is selected. `manager ingest` calls
`scripts/dev-studio-ingest-resolve.sh`; `manager analyze` calls
`scripts/manager-analyze.sh`; `manager reconcile` calls
`scripts/manager-reconcile.sh`; `manager work-chain` calls
`scripts/manager-work-chain.sh`. For chain orchestration, bare
`scripts/studio-chain-runner.sh` now shows runnable chains, resumable runs, and
next-action commands before any plan or resume action is chosen. Use
`--discover <manifest|chain-name>` for filtered discovery; `/dev-studio manager
work-chain prd-to-chain-automation` auto-runs the new PRD automation chain
while bare `manager work-chain` still lands in discovery. Chain execution
supports explicit `--attended` and `--unattended` modes; unattended runs avoid
routine continue prompts and stop only on typed blockers after finite retries.

After a bare role landing, later bare subcommands may resolve through that
active role when unambiguous in the same session. Store the resolved canonical
role after alias resolution. Explicit `/dev-studio <role> ...` always wins and
replaces the active role for that invocation; bare `/dev-studio` re-lands in
manager and clears any assumed active-role shortcut. Ambiguous commands require
the role prefix or a lightweight clarification.

<!-- v2-dev-studio:intent -->
## Intent detection

Priority: explicit canonical role, compatibility alias, former top-level name,
session-local active-role command when unambiguous, bare role landing, then
manager landing. Unknown role tokens fail before side effects.

<!-- v2-dev-studio:forwarders -->
## Forwarders

Compatibility alias state is data in `forwarders.yaml`. Post-A10,
`forwarders: []` is expected. Aliases do not add business logic, bypass role
contracts, or widen permissions.
