---
name: dev-studio
description: Studio v2 umbrella router for canonical roles. Routes `/dev-studio` invocations and documents post-A10 compatibility aliases for former top-level agent names.
type: agent-router
schema_version: 1
version: 0.1.0
---

# dev-studio — Studio v2 Umbrella Router

`/dev-studio` is the Studio v2 entrypoint and primary traffic surface. It routes
by canonical role first and keeps former top-level names as compatibility
aliases. A10 records v2 as the only active traffic surface in
`core/v2/cutover/manifest.yaml`; the v1 router surfaces are deleted from the
repo and recoverable only from git history.

Pattern contract: `core/v2/SPEC.md` §Roles and Handoffs. Canonical roles and
compatibility aliases: `core/v2/registry/roles.json`. Forwarder manifest:
`core/v2/skills/dev-studio/forwarders.yaml`.

<!-- v2-dev-studio:scope -->
## Scope

The router chooses the role contract for an invocation. Mode procedure,
authority checks, handoff validation, event emission, and project-profile
commands stay outside this router.

Former top-level skills (`/chanakya`, `/achilles`, `/argus`, `/apollo`) are no
longer repo-local router surfaces after A10. Their compatibility meaning is
preserved as `/dev-studio <alias>` role resolution and documented in
`forwarders.yaml`.

<!-- v2-dev-studio:dispatch -->
## Dispatch table

| Invocation | Canonical role | Compatibility names | Status |
|---|---|---|---|
| `/dev-studio manager ...` | `manager` | `chanakya`, `coordinator`, `orchestrator` | v1 deleted |
| `/dev-studio worker ...` | `worker` | `achilles`, `implementer` | v1 deleted |
| `/dev-studio reviewer ...` | `reviewer` | `argus`, `verifier` | v1 deleted |
| `/dev-studio perf ...` | `perf` | `apollo`, `performance`, `performance-engineer` | v1 deleted |
| `/dev-studio planner ...` | `planner` | `architect`, `luban`, `lu-ban` | reserved for A7+ |
| `/dev-studio qa-engineer ...` | `qa-engineer` | `qa`, `chiron`, `synthetic-qa` | reserved for A7+ |
| `/dev-studio flow-tester ...` | `flow-tester` | `flow`, `manual-qa`, `exploratory-tester` | reserved for A7+ |
| `/dev-studio release-manager ...` | `release-manager` | `release`, `shipper` | reserved for A7+ |
| `/dev-studio host-adapter ...` | `host-adapter` | `adapter`, `host` | reserved for adapter operations |
| `/dev-studio operator ...` | `operator` | `user`, `human`, `owner` | reserved, non-routable human authority |

<!-- v2-dev-studio:landing -->
## Bare Role Landing

When the invocation names a role but no target or subcommand, start that role in
a lightweight conversational landing instead of running a heavy default action.
Load the role contract, identify the current repo/profile, and offer a short
set of likely next moves. The user can then describe the desired work in plain
language without retyping `/dev-studio`.

After the user locks in a path, continue into the selected workflow and report
the direct one-line invocation they can use next time. Existing explicit
invocations keep routing directly and do not show the landing.

Landing suggestions are cwd/profile-aware. Studio-internal options such as
`ingest`, `audit`, `guard`, `sync`, `nodes`, and `resume-plan` target
`generic-dev-studio` unless the user explicitly asks for studio operations from
another project. Project repositories should bias suggestions toward project
task shaping, implementation, review, QA, flow testing, performance, and
release readiness.

<!-- v2-dev-studio:intent -->
## Intent detection

Priority order:

1. **Explicit canonical role** — `/dev-studio worker <contract>` routes to the
   `worker` role.
2. **Compatibility alias** — `/dev-studio achilles <contract>` resolves
   `achilles` through `scripts/v2-role-resolve.sh` and routes to `worker`.
3. **Former top-level name** — `/dev-studio achilles <contract>` keeps the
   old role name available without restoring the deleted v1 router.
4. **Bare role token** — `/dev-studio reviewer` or `/dev-studio
   release-manager` starts that role's lightweight landing.
5. **No role token** — route to the `manager` landing; the manager owns
   conversational shaping and status.

Unknown role tokens fail before side effects with the explicit resolver error.
Routing intelligence remains advisory unless a role contract grants authority.

<!-- v2-dev-studio:forwarders -->
## Forwarders

Compatibility alias state is data, not duplicated router prose. The
schema-bearing manifest at `forwarders.yaml` is the source for adapter-specific
command surfaces and transition docs. During a rollback window, a forwarder row
names:

- the legacy invocation;
- the canonical role;
- the v2 invocation template;
- the v1 skill path it preserves during transition;
- whether runtime traffic has cut over.

Post-A10, `forwarders: []` is the expected state. Aliases do not add business
logic, bypass role contracts, or widen permissions.
