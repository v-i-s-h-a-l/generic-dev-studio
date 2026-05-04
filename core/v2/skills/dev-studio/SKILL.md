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
commands stay outside this router. Checkpoint storage, schema details, budget
telemetry, and resume lazy-load policy stay in `core/v2/checkpoints/CONTRACT.md`.

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

<!-- v2-dev-studio:lifecycle -->
## Lifecycle Actions

`checkpoint` and `resume-checkpoint` are cross-role lifecycle actions. The
router resolves the role first and leaves checkpoint content to that role's
contract:

| Invocation | Route | Behavior |
|---|---|---|
| `/dev-studio checkpoint ...` | `manager` landing | Shape the request, identify the intended role, and suggest the explicit role command. |
| `/dev-studio resume-checkpoint ...` | `manager` landing | Shape resume intent, find the likely role or checkpoint selector, and avoid loading specialist state until routed. |
| `/dev-studio <role> checkpoint ...` | selected role | Create or update a role-owned compact checkpoint using the shared checkpoint contract. |
| `/dev-studio <role> resume-checkpoint ...` | selected role | Load `manifest.json` and `context.md` first, then lazy-load role-owned state only as needed. |

Checkpoint artifacts preserve compact resume context. They do not replace
worker summaries, reviewer verdicts, release packets, QA or flow checklists,
perf verdicts, or durable event logs.

<!-- v2-dev-studio:manager-analyze -->
## Manager Analyze Feedback Routing

`/dev-studio manager analyze` is a workflow manager for studio-scoped feedback,
not a passive report generator. After writing the private analysis report, it
runs `scripts/analyze-feedback-ingest.sh --apply` from the studio repo so each
safe actionable feedback record reaches a durable issue destination.

The manager must search existing GitHub issues before filing, comment or update
a clearly covered issue, create one issue only for distinct work, and move a
source record to `processed/` only after the destination exists. Unsafe public
records stay in the inbox with a policy reason. Final output includes the
remaining inbox count and the destination list.

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

Landing suggestions are cwd/profile-aware. Studio-internal options (`audit`,
`guard`, `sync`, `nodes`, `resume-plan`) target `generic-dev-studio` unless the
user explicitly asks for studio operations from another project. `manager
ingest` calls `scripts/dev-studio-ingest-resolve.sh`; default ingest follows
the current git repository, and Forge/Studio ingest requires explicit `--scope
studio` or `--to generic-dev-studio`. Project repositories should bias
suggestions toward project task shaping, implementation, review, QA, flow
testing, performance, and release readiness.

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
