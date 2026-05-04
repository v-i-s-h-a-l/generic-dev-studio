# Studio v2 Substrate SPEC

Status: A0.5 signed-off substrate specification for #444 / #513.

<!-- v2-bootstrap:a0.5-sign-off:complete -->

This file is the normative Studio v2 substrate contract. It composes the A0
research pass, A0a host capability matrix, A0b durable event-log semantics, A0c
auth and permissions model, A0d role topology and handoff RFC, and A0.4 bootstrap
gate. Post-bootstrap implementation may proceed only when changes conform to
this SPEC and the A0.6 enforcement gates derived from it.

<!-- v2-spec:source-inputs -->
## Source Inputs

The SPEC consumes these reviewed inputs:

- A0 research map: patterns are adopted, frameworks are not. The core remains
  file artifacts, schemas, shell-reachable validators, and host adapters.
- A0a host capability matrix: load-bearing paths assume repo/runtime file I/O,
  POSIX shell, explicit instruction files, deterministic handoff artifacts, and
  JSON Schema validation only.
- A0b durable event-log semantics: append-only JSONL remains the fact stream;
  subscribers own replay checkpoints and lag handling.
- A0c auth and permissions model: every mutating action declares filesystem,
  command, secret, mutation, interactivity, and failure authority before side
  effects.
- A0d role topology and handoff RFC: canonical roles communicate through typed
  artifacts and explicit decision rights, not implicit conversation state.
- A0.4 bootstrap gate: the initial gate enforces only bootstrap/meta rules until
  this sign-off marker exists.

<!-- v2-spec:principles -->
## Principles

Studio v2 is substrate-first and host-agnostic. The user is the operator and
escape hatch; routine planning, execution, review, testing, and release packet
assembly should be automated behind explicit contracts.

The core must not depend on host-only conveniences such as SessionStart hooks,
slash commands, subagent APIs, host-specific tool names, MCP availability, or
inherited secret environments. Host adapters may expose those features as
ergonomic accelerators when a portable artifact-and-shell path or a loud
unsupported state also exists.

Major plans, phase boundaries, and substrate changes require sibling-host review
through the smoke-gated review wrapper. Assistants must not bypass review,
permission, release, or destructive gates on their own initiative. Any override
belongs to the operator and must be recorded in the relevant artifact.

Task size discipline is part of the substrate. Planners decompose L/XL work into
S/M executable leaves and combine related XS leaves only when doing so reduces
handoff overhead without hiding acceptance criteria.

<!-- v2-spec:host-floor -->
## Host Capability Floor

Every load-bearing role invocation may assume only:

- reads and writes inside the owned repo worktree;
- runtime artifact reads and writes under `~/.dev-studio/**`;
- a POSIX shell or host-equivalent command runner;
- a repo-provided instruction artifact for the selected host;
- JSON/YAML/Markdown artifacts with declared schemas or anchors;
- explicit success, blocked, unsupported, unknown, or failure outputs.

Hosts declare capabilities as data. Unknown capability is denial for mutation
and a caveated state for read-only planning. Unsupported capability halts before
side effects and reports host, role, required capability, and the expected setup
or alternate host.

At least Claude Code and one non-Claude host must exercise the same manager
artifact contracts before A7 proof-of-life is accepted. Concrete model names are
resolved through model-role policy and host capability manifests, never hardcoded
in substrate contracts.

<!-- v2-spec:artifact-root -->
## Artifact and Namespace Model

V2 uses a parallel root namespace. Bootstrap artifacts live under `core/v2/`.
Runtime artifacts live under `~/.dev-studio/<project>/` or
`~/.dev-studio/.runtime/` according to the shared file-location contract.

Source-of-truth artifacts are append-only logs, versioned schemas, manifests,
and typed handoff files. Derived views, dashboards, indexes, and docs surfaces
are rebuildable and must not become the only copy of a load-bearing fact.

All new substrate artifacts carry either a JSON Schema or a named anchor list
that a lint can validate. Schema-bearing artifacts include `schema_version`.
Anchor-bearing Markdown files use exact HTML comments so scripts can check them
without loading prose into an agent context.

<!-- v2-spec:event-log -->
## Durable Event Log

The event log is the durable fact stream:

```text
<project-runtime>/events/<YYYY-MM-DD>.jsonl
```

Each line is one complete bounded JSON object. Producers append; they do not
rewrite, sort, truncate, rotate, or delete active shards. Large payloads are
written as durable artifacts first and referenced by bounded event payloads.

Authoritative replay order is `(shard_date, byte_offset)`. Timestamps are
observability metadata and do not define ordering. Event append is at-least-once.
Consumers dedupe logical writable actions by `(producer.agent, idempotency_key)`
and keep the first event in shard/offset order. Events without idempotency keys
are non-dedupable observations.

Subscribers own checkpoints that record subscriber name, shard, next byte offset,
updated timestamp, and optional last event id. They atomically replace checkpoints
after their side effects are durable. Missing shards, offsets beyond EOF, partial
lines, and malformed JSON are explicit recovery or dead-letter states, not silent
skips.

The log itself has no global write lock. Locks belong to resources, producers,
or subscriber-local checkpoint writes. Subscriber lag is surfaced as status or
events with subscriber name, pending bytes or offsets, oldest unprocessed shard,
and severity.

<!-- v2-spec:auth-permissions -->
## Auth and Permissions

Every mutating action declares an authority manifest or generated equivalent:

```yaml
action: <name>
role: <manager|planner|worker|reviewer|qa-engineer|flow-tester|perf|release-manager|host-adapter|helper>
filesystem:
  reads: []
  writes: []
commands: []
secret_scopes: []
mutation_scopes: []
interactive: false
headless_safe: true
failure_classes: []
override: null
```

Declarations are checked against the selected host profile before the first
irreversible side effect. Authority does not flow by assumption from a parent
session to a child process, worker, reviewer, release helper, or host-native
subagent.

GitHub CLI calls initiated by assistants route through `scripts/studio-gh.sh` or
the v2 successor wrapper. Scripts that perform GitHub mutations or remote
credential probes use login-home normalization. Raw `gh` is not a load-bearing
path.

Release actions are higher-risk boundaries. TestFlight, App Store, Slack,
signing, and GitHub release mutation scopes are distinct. Fallback from an
unauthorized host to another host is a new authority decision and requires
preflight evidence before mutation.

Auth and permission failures are explicit terminal classes: `unsupported`,
`unknown`, `missing`, `denied`, `expired`, or `partial`. A partial mutation
returns a recovery artifact naming what changed, what failed, and the stable
idempotency key.

<!-- v2-spec:roles-handoffs -->
## Roles and Handoffs

Canonical roles are `manager`, `planner`, `worker`, `reviewer`, `qa-engineer`,
`flow-tester`, `perf`, `release-manager`, `host-adapter`, and `operator`.
Compatibility names such as `chanakya`, `achilles`, `argus`, and `apollo`
resolve through `core/v2/registry/roles.json` and
`scripts/v2-role-resolve.sh`; role contracts use canonical names.

Every executable role contract declares purpose, inputs, outputs, reads, writes,
idempotency key, decision rights, escalation triggers, failure semantics, and
verification floor. Extracted helpers follow the same minimum before code moves.
Planner owns scope shaping, reusable API discovery, task decomposition, and
acceptance criteria for shaped work; irreducible conflicts over scope, priority,
authority, or user-visible tradeoffs escalate back to manager before dispatch.
QA engineer owns automated test contracts with partial multi-spawn completion
semantics; flow tester owns scenario-level user-flow evidence and severity
thresholds; release manager owns release readiness packets and blocks external
release actions until operator approval exists.

Handoff artifacts use this shared envelope:

```yaml
schema_version: 1
artifact_kind: <planner-output|worker-contract|qa-contract|reviewer-verdict|flow-test-checklist|release-packet>
artifact_id: <stable-id>
created_at: <UTC timestamp>
producer_role: <role>
consumer_role: <role>
subject_ref: <issue|task|phase|release ref>
idempotency_key: <stable retry key>
payload: {}
evidence_refs: []
privacy_classification: <public|private-runtime|secret>
status: <draft|ready|blocked|approved|rejected|completed|partial>
```

Required handoff families:

- `planner-output`: scope, dependencies, risks, acceptance criteria, and review
  ask for an epic, phase, or batch.
- `worker-contract`: issue/task reference, ownership, allowed files, checks,
  stop conditions, and summary artifact path.
- `qa-contract`: task contract reference, test strategy, QA targets, required
  checks, partial completion rule, and escalation state.
- `reviewer-verdict`: blocking findings, warnings, evidence reviewed, and
  explicit `nothing_fatal` status when clean.
- `flow-test-checklist`: scenario IDs, severity, pass/fail/blocked state,
  evidence refs, distinction from QA/reviewer, and merge-block rule.
- `release-packet`: release scope, anchor issues, notes state, build/release
  message state, tag/GitHub release/TestFlight/App Store states, and blockers.

Routing intelligence is advisory unless a contract grants authority. Novelty,
architectural concern, or model-role recommendations produce suggestions or
reviewed plans; they do not silently reroute work.

<!-- v2-spec:project-profiles -->
## Project Profiles

Generic core knows abstract operations such as `build`, `test:unit`, `test:ui`,
`lint`, `format`, `release:beta`, and `release:prod`. Project profiles map those
operations to platform-specific commands, environment, secrets, simulator or
device resources, manual-test workflows, and profile-local rules.

The first complete profile is iOS. Non-iOS stacks remain substrate-compatible
through the same profile shape but are not implemented until a real project
needs them.

Normal profile commands and rules must not require core code changes. A profile
may use an explicit plugin escape hatch only when the profile declares the new
authority, commands, generated artifacts, and failure behavior.

Project-specific guidance can extend behavior without forking core skills and
without token cost when absent. Secrets resolve per project first, then through
documented migration or legacy fallback paths until A6 removes the fallback.

<!-- v2-spec:context-budget -->
## Context and Skill Loading

Context loading is role-aware, skill-aware, and invocation-aware. Agents load the
minimum source artifacts needed for the current contract. Long always-loaded
instructions are not the substrate.

Vendored third-party skills are version-pinned in the repo. Host global skill
registries are not mutated by project work. Host-native skill systems may load
the same vendored artifacts through adapters, but the repo remains the source of
truth for skill content and portability metadata.

A3 implements this as the read-only `scripts/v2-skill-load.sh` primitive plus
`core/v2/schemas/vendored-skill-artifact.schema.json`. The loader resolves only
repo-vendored skills under `skills/vendored/**`, validates each artifact's
`vendor.yaml` pin and `portability.yaml` host/scope declaration, and returns a
path, prompt body, or normalized JSON artifact for later A3b/A5 consumers.

Intelligent skill routing is data-driven. `core/v2/skills/routing-rules.yaml`
maps canonical Studio v2 roles, invocation phases, task types, stacks, paths,
and prompt signals to required skills; `scripts/v2-skill-route.sh` resolves the
rules against a JSON context before consumers load skill content. Routing rules
select skills only; they do not mutate host registries or embed skill guidance.

Context-budget enforcement is a shared subsystem, not duplicated prose inside
each role. A5 defines budgets and telemetry in
`core/v2/context-budget/manifest.json`; `scripts/v2-context-budget.sh` resolves
the effective role + skill + invocation ceiling for a contract and can emit a
static role-surface report with `--report`. A0.6 ensures new role contracts
declare what they read before relying on it.

Sibling-review value is recorded as explicit manager/operator disposition data,
not inferred from raw finding count. `core/v2/review/metrics.yaml` defines
severity weights and dispositions; `scripts/v2-review-metrics.sh` emits private
runtime events and reports accepted weighted score by phase and review host.

Worker + QA parallelism is piloted with deterministic lanes before model-host
dogfooding. `core/v2/pilots/multispawn-budgets.yaml` defines coordination
overhead budgets; `scripts/v2-multispawn-pilot.sh` records worker/qa-engineer
start/end times, stable-contract state, terminal state, and topology failure
events for partial completion or budget exhaustion.

<!-- v2-spec:testing-release -->
## Testing, Review, and Release Workflow

Primitive logic, validators, schemas, parsers, and pure helpers are tested while
they are built. Feature-integration tests harden after acceptance criteria settle
unless the behavior is a known user-facing flow; UI tests are developed with the
feature when the flow is known.

Workers verify their assigned contract but do not accept their own work.
Reviewers return verdict artifacts; managers route acceptance; operators approve
irreversible, ambiguous, destructive, permission-expanding, or externally visible
decisions.

Every TestFlight build gets an updated manual flow checklist tied to what
changed. Every TestFlight build is tagged. Every App Store release has GitHub
release notes. A11 owns product-facing build and release message style plus
duplicate-detection linting.

<!-- v2-spec:bootstrap-gate -->
## Bootstrap Gate and A0.6 Enforcement

A0.4 is intentionally narrow. Its required anchors are:

- `<!-- v2-bootstrap:a0.4-scope -->`
- `<!-- v2-bootstrap:schema-presence -->`
- `<!-- v2-bootstrap:required-anchors -->`
- `<!-- v2-bootstrap:pre-a0.5-code-freeze -->`
- `<!-- v2-bootstrap:a0.6-deferred-rules -->`

The A0.5 sign-off marker is the exact line near the top of this file:

```text
<!-- v2-bootstrap:a0.5-sign-off:complete -->
```

Before that marker exists in `core/v2/SPEC.md`, the bootstrap lint blocks
substrate implementation code under `core/` and `profiles/`. After the marker
exists, A0.4 no longer blocks code solely for being post-A0.5 substrate code.
A0.6 then extends enforcement from this SPEC.

A0.6 enforcement must add or generate checks for:

- schema presence and schema-version fields for all handoff artifacts;
- host capability manifests and unsupported/unknown failure behavior;
- permission manifests for mutating actions;
- event-line validity, event name registration, bounded payloads, writable
  idempotency keys, and subscriber checkpoint coordinates;
- role contract minimum fields and handoff envelope validity;
- router complexity and no-business-logic constraints;
- project-profile command/rule boundaries;
- automation-mode-first docs guidance;
- phase-review wrapper usage for phase boundaries and substrate changes.

A0.6 may not silently broaden permissions, remove operator overrides, or convert
warning-tier review feedback into hidden implementation behavior.

<!-- v2-spec:carryover -->
## Carryover

- A0.6 turns this SPEC into schemas, pre-commit hooks, CI checks, and invariant
  validators.
- A1 defines role registry and alias resolution in
  `core/v2/registry/roles.json`, validated by
  `scripts/test-fixtures/515-role-registry/test-role-registry.sh`.
  The A1 schema fixes the canonical role set for this phase; future registry
  expansion must either retire the A1 `parent_issue`/`leaf_issue` constants or
  fork the schema deliberately.
- A2 defines the `/dev-studio` umbrella router and v1 compatibility forwarders
  in `core/v2/skills/dev-studio/`. A2a implements the modular router contract
  and complexity/no-business-logic lint.
- A3 ships vendored skill loading and pin validation via
  `scripts/v2-skill-load.sh`; A3b/A3c add routing intelligence and the iOS skill
  catalog.
- A4 implements durable event append, replay checkpoints, subscriber dedupe,
  dead-letter artifacts, and lag status via `scripts/v2-event-log.sh`. A4a
  implements v1 chain-run counters and weekly digest output via
  `scripts/studio-chain-telemetry-digest.sh`, which also feeds private chain
  reports generated by `scripts/studio-chain-runner.sh`.
- A5 implements context-budget enforcement through the shared manifest and
  resolver.
- A6 implements project profiles and iOS profile behavior through
  `scripts/v2-profile.sh`, `core/v2/schemas/project-profile.schema.json`, and
  the `profiles/ios-turnip/` profile.
- A11 implements build/release message style and same-draft duplicate linting
  through `core/v2/MESSAGES.md` and
  `scripts/lint-build-release-message.sh`.
- A7 proves manager v2 on the substrate before broader migration through
  `core/v2/manager/proof-of-life.yaml` and `scripts/v2-manager.sh`, without
  adding a new handoff artifact kind or switching v1 traffic.
- A8/A9/A10 migrate remaining roles, archive v1, switch traffic, and delete v1
  only after the stability window and operator sign-off.
