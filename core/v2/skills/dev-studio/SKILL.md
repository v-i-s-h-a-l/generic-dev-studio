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
`scripts/manager-reconcile.sh`.

<!-- v2-dev-studio:intent -->
## Intent detection

Priority: explicit canonical role, compatibility alias, former top-level name,
bare role landing, then manager landing. Unknown role tokens fail before side
effects.

<!-- v2-dev-studio:forwarders -->
## Forwarders

Compatibility alias state is data in `forwarders.yaml`. Post-A10,
`forwarders: []` is expected. Aliases do not add business logic, bypass role
contracts, or widen permissions.
