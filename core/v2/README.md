# Studio v2 Substrate

This directory is the parallel v2 substrate root for #444. `SPEC.md` is signed
off for post-bootstrap implementation; new v2 leaf work should land here with
schemas, tests, and a shell-reachable primitive when behavior is executable.

Current substrate artifacts:

- `bootstrap.yaml` declares the A0.4 gate surface.
- `BOOTSTRAP.md` names the required human-readable anchors.
- `schemas/bootstrap.schema.json` defines the bootstrap manifest shape.
- `hooks/pre-commit` is the v2-local hook entry point; the repo hook delegates
  to `scripts/lint-v2-bootstrap.sh`.
- `registry/roles.json` is the A1 canonical role registry. Resolve canonical
  names and compatibility aliases with `scripts/v2-role-resolve.sh`.
- `roles/*.yaml` contains executable role contracts for the migrated planner,
  worker, reviewer, qa-engineer, flow-tester, perf, and release-manager roles.
  Validate or resolve them with `scripts/v2-role-contract.sh`.
- `schemas/handoff.schema.json` and `handoffs/*.yaml` define role-specific
  handoff validation fixtures for planner output, QA contracts, flow-test
  checklists, and release packets.
- `skills/dev-studio/` is the A2 umbrella skill. It defines `/dev-studio`,
  lists canonical role dispatch rows, and records v1 compatibility forwarders
  for `/chanakya`, `/achilles`, `/argus`, and `/apollo`.
- `cutover/manifest.yaml` and `cutover/ROLLBACK.md` are the A9 archive,
  traffic-switch, parity, and rollback playbook. Validate the cutover state
  with `scripts/v2-cutover.sh --validate`.
- `routers/modular-router-contract.yaml` and
  `schemas/router-contract.schema.json` define the A2a modular router contract.
  Validate router contracts and shell router boundaries with
  `scripts/v2-router-lint.sh`; the A0.6 gate delegates to it.
- `scripts/v2-skill-load.sh` is the A3 vendored skill loader. It resolves
  `skills/vendored/**` artifacts by skill name, validates their repo-pinned
  `vendor.yaml` SHA and portability metadata, and emits a normalized JSON
  artifact matching `schemas/vendored-skill-artifact.schema.json`.
- `skills/routing-rules.yaml` is the A3b role-aware skill routing ruleset.
  Resolve a task context to required skills with `scripts/v2-skill-route.sh`.
- `skills/ios/catalog.yaml` is the A3c iOS skill catalog manifest. It is
  catalog content only: A3 owns vendored skill loading, and A3b owns advisory
  skill-routing rules and resolver behavior.
- `context-budget/manifest.json` is the A5 unified context-budget policy for
  role, skill, and invocation ceilings. Resolve and check effective budgets with
  `scripts/v2-context-budget.sh`; emit static role-surface evidence with
  `scripts/v2-context-budget.sh --report`.
- `schemas/durable-event.schema.json` defines the bounded JSONL event envelope.
- `schemas/subscriber-checkpoint.schema.json` defines durable replay coordinates.
- `schemas/subscriber-lag.schema.json` defines subscriber lag status artifacts.
- `schemas/dead-letter.schema.json` defines malformed/partial-line dead letters.
- `events/registry.yaml` is the v2 event-name registry seed for subscriber
  operational events, topology runtime failures, and review finding disposition
  metrics.
- `review/metrics.yaml` defines sibling-review severity weights and disposition
  values. Record and report review finding value with
  `scripts/v2-review-metrics.sh emit ...` and
  `scripts/v2-review-metrics.sh report --format markdown|json`.
- `schemas/project-profile.schema.json` defines profile-owned operation
  mappings. Resolve and validate profile commands with `scripts/v2-profile.sh`;
  the first profile is `profiles/ios-turnip/`.
- `MESSAGES.md` defines A11 build/release message shape. Validate same-draft
  duplicates with `scripts/lint-build-release-message.sh`.
- `manager/proof-of-life.yaml` defines the A7 manager proof-of-life contract.
  Exercise it with `scripts/v2-manager.sh proof-of-life --subject-ref <ref>
  --dry-run` or provide `--runtime-root` to write the private runtime artifact
  and append the registered `manager_proof_of_life` event.

Runtime event-log behavior is implemented by `scripts/v2-event-log.sh`:

```bash
scripts/v2-event-log.sh append --runtime-root ~/.dev-studio/<project> --event-json '<json>'
scripts/v2-event-log.sh replay --runtime-root ~/.dev-studio/<project> --subscriber <name>
scripts/v2-event-log.sh lag --runtime-root ~/.dev-studio/<project> --subscriber <name> --write-status
```

The primitive appends bounded one-line JSON events to
`events/YYYY-MM-DD.jsonl`, replays from per-subscriber checkpoints, dedupes
keyed events by `(producer.agent, idempotency_key)`, writes malformed input to a
dead-letter directory when requested, and reports lag without blocking producers.
