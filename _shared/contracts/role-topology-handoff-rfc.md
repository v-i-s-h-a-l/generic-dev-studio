---
name: Role Topology and Handoff Contract RFC
schema_version: 1
description: Normative Studio v2 RFC for role contracts, handoff artifacts, decision rights, and contract-level failure semantics.
type: contract
---

# Role Topology and Handoff Contract RFC

Status: normative RFC for Studio v2 A0d. A0.5 `SPEC.md` consumes this document as the source of truth for role contracts and handoff artifact requirements. A0.6 turns the requirements into schemas, hooks, and CI gates.

## Goals

- Define Studio v2 roles by responsibility instead of mythology aliases or host-specific tools.
- Define the handoff artifact families that cross role boundaries.
- Make decision rights explicit so automation can proceed without silently stealing user authority.
- Specify contract-level failure semantics that every host adapter and role implementation must preserve.

## Non-Goals

- This RFC does not implement v2 agents, migrate v1 skills, or define the final file layout under the future v2 root.
- This RFC does not replace existing v1 contracts such as `handoff.schema.json`; those remain active until v2 cutover.
- This RFC does not choose concrete model names. Model-role resolution stays governed by `ARCHITECTURE.md` and host capability manifests.

## Topology

Studio v2 is hub-and-spoke for state mutation and contract acceptance. The manager owns orchestration policy and lifecycle state. Specialists own bounded artifacts and return typed results to the manager. Peer-to-peer worker mutation is forbidden unless a later RFC explicitly introduces a broker with equivalent auditability.

| Role | Primary Responsibility | May Mutate | Must Not Mutate |
|---|---|---|---|
| `manager` | Intake, prioritization, lifecycle state, dispatch, status, user escalation, final acceptance routing. | Project ledger, issue/task metadata, dispatch records, event log entries for orchestration decisions. | Worker worktrees, review verdict payloads, profile command implementations. |
| `planner` | Convert shaped intent into executable plans, dependency graphs, acceptance criteria, and worker contracts. | Planner-output artifacts and plan-review response artifacts. | Task execution state after dispatch; source files in task worktrees. |
| `worker` | Implement one bounded task contract in an isolated worktree. | Assigned worktree files, worker summary/debrief artifacts, verification evidence for its task. | Planner outputs, reviewer verdicts, release packets, unrelated worktrees. |
| `reviewer` | Verify plan/spec compliance, code quality, safety gates, and contract adherence. | Reviewer-verdict artifacts and append-only review events/back-refs. | Worker source edits, task acceptance state, release approvals. |
| `qa-engineer` | Produce and execute automated test contracts beyond the worker's local checks. | QA-contract results, test evidence artifacts, test-run events. | Product code outside an explicitly assigned test-fix task. |
| `flow-tester` | Produce human/manual exploratory flow checklists tied to builds and releases. | Flow-test-checklist artifacts and results. | Release approval state or product code. |
| `perf` | Investigate performance, battery, memory, thermal, and instrumentation evidence. | Performance reports, evidence indices, perf verdicts. | Functional acceptance state without manager routing. |
| `release-manager` | Assemble beta/prod release packets, verify release prerequisites, draft release notes. | Release-packet artifacts, release-preflight events, tag/release drafts when explicitly authorized. | User sign-off, App Store production submission approval, base-branch integration bypasses. |
| `host-adapter` | Expose host capabilities as data and execute portable role invocations. | Adapter manifests, host-run telemetry, normalized spawn/dispatch records. | Role policy, artifact semantics, silent capability downgrades. |
| `operator` | Human/user authority for irreversible, ambiguous, or externally visible decisions. | Explicit approvals, overrides, issue comments, release/sign-off decisions. | Machine-generated evidence fields. |

Aliases such as `chanakya`, `achilles`, `argus`, and `apollo` are compatibility labels. V2 contracts use canonical role names. A1 owns alias resolution.

## Role Contract Minimum

Every executable role contract must declare:

| Field | Requirement |
|---|---|
| `role` | Canonical role name from this RFC or a future SPEC extension. |
| `purpose` | One-sentence responsibility boundary. |
| `inputs` | Validated artifact types the role accepts. |
| `outputs` | Validated artifact types the role emits. |
| `reads` | Artifact families and filesystem roots read by the role. |
| `writes` | Artifact families and filesystem roots written by the role. |
| `idempotency_key` | Stable retry key for any mutating invocation. |
| `decision_rights` | Decisions the role may make without user input. |
| `escalation_triggers` | Conditions that must return `blocked`, `needs_context`, or `requires_approval`. |
| `failure_semantics` | Loud failure behavior for invalid input, missing capability, stale state, and partial output. |
| `verification_floor` | Minimum evidence required before the role may claim completion. |

Helpers extracted from a role follow the same minimum. A helper is contract-valid only when it defines input artifact, output artifact, idempotency key, event emitted, and failure behavior before implementation moves.

## Handoff Artifact Families

The artifacts below are the A0d contract families. A0.5 defines exact schemas and storage paths; A0.6 validates them.

| Artifact | Producer | Consumer | Purpose |
|---|---|---|---|
| `planner-output` | `planner` | `manager`, `reviewer` | Structured plan for an epic, phase, or task batch. Includes scope, dependencies, risks, acceptance criteria, and review ask. |
| `worker-contract` | `manager` or `planner` | `worker`, `reviewer` | Bounded executable task. Includes issue/task reference, ownership, allowed files, required checks, stop conditions, and summary artifact path. |
| `qa-contract` | `manager` or `planner` | `qa-engineer`, `reviewer` | Test objective, target build/worktree, scenarios, environment, expected evidence, and pass/fail semantics. |
| `reviewer-verdict` | `reviewer` | `manager`, producing role | Typed verdict for a plan, diff, outcome, release packet, or QA result. Includes blocking findings, warnings, evidence reviewed, and explicit `nothing_fatal` status when clean. |
| `flow-test-checklist` | `flow-tester` or `release-manager` | `operator`, `manager` | Manual flow checklist tied to a build or release packet. Includes setup, steps, expected observations, and result capture fields. |
| `release-packet` | `release-manager` | `reviewer`, `operator`, `manager` | Beta/prod release bundle. Includes commits/issues included, verification evidence, release notes draft, rollback notes, approvals required, and tag/build metadata. |

All handoff artifacts share these envelope requirements:

- `schema_version`
- `artifact_kind`
- `artifact_id`
- `created_at`
- `producer_role`
- `consumer_role`
- `subject_ref`
- `idempotency_key`
- `payload`
- `evidence_refs`
- `privacy_classification`
- `status`

`payload` may be inline only when it stays within the event-log atomicity threshold defined by the active event contract. Larger payloads use a filesystem reference and a hash.

## Decision Rights

| Decision | Default Authority | Notes |
|---|---|---|
| Shape an ambiguous request into a first runnable plan | `manager` | Must surface material scope changes and non-goals. |
| Decompose an L/XL request into S/M tasks | `planner` with `manager` acceptance | Planner proposes; manager accepts and dispatches. |
| Start a worker task from a reviewed contract | `manager` | Requires required phase gates to be clean. |
| Modify assigned source files | `worker` | Limited to the worker contract's ownership boundary. |
| Declare implementation complete | `worker` | Requires verification floor; completion is not acceptance. |
| Accept or reject a plan/outcome review gate | `reviewer` | Clean gate means `nothing_fatal`, not user approval. |
| Close an issue or mark a phase accepted | `manager` | Must reference artifact evidence and preserve carryover. |
| Bypass a gate or override a stop condition | `operator` | Assistants must not self-bypass; overrides must be recorded. |
| Tag, submit, or ship externally visible release output | `operator` | Release-manager prepares packets; user approves irreversible steps. |

Routing intelligence is advisory unless a contract explicitly grants authority. Novelty detection, architectural-concern flags, and model-role recommendations produce suggestions or reviewed plans; they do not silently reroute work.

## Failure Semantics

Contracts fail loudly. A role may return a typed blocked status, but it must not silently skip a required step or downgrade a missing capability into success.

| Failure | Required Behavior |
|---|---|
| Invalid artifact schema | Stop before side effects; emit `contract_invalid` with validator output and artifact reference. |
| Unsupported host capability | Stop before side effects; emit `capability_unsupported` naming host, role, missing capability, and required fallback or operator action. |
| Missing or stale context | Return `needs_context` with the exact missing input and the artifact that needs regeneration. |
| Ownership conflict | Stop; emit `ownership_conflict` with conflicting files/artifacts and do not merge or mutate unrelated state. |
| Verification unavailable | Return `done_with_concerns`, `blocked`, or `verification_skipped_with_reason`; never claim `done` or `green` without evidence. |
| Partial output written | Emit `partial_output` with cleanup/retry guidance and idempotency key; receiver must not treat it as accepted. |
| Reviewer warning | Preserve warning text in outcome artifacts when the overall verdict is non-blocking. |
| User approval required | Return `requires_approval`; do not proceed through release, destructive, permission, or external visibility boundaries. |

Retries are valid only when the idempotency key is stable and the previous attempt did not cross an irreversible boundary. Validators, permission failures, and user-approval boundaries are not auto-retryable.

## Host-Agnostic Requirements

- Load-bearing paths use file I/O, POSIX shell, explicit artifacts, and one model session.
- Host-specific conveniences such as slash commands, child-agent APIs, hooks, or startup-context injection are optional adapters, not required substrate.
- Capability manifests gate feature use before invocation.
- Host differences surface as explicit errors or `unknown`, never as silent no-ops.
- Tool dialect names must not appear in role contracts as requirements.

## End-of-Session and Resume Contracts

Session close is a manager-invoked job contract, not fuzzy prose. It must drain pending handoff/debrief inboxes, check unpushed commits and pending push/release queues, emit `agent_session_completed`, and return a `safe_to_exit` or `wait` result with reasons.

Resume recovery uses the same contract family. If the last `agent_session_completed` is absent or stale and later activity exists, the manager must run self-healing cleanup/backfill before normal startup. A0.5 defines the freshness threshold and artifacts.

## A0.5 Schema Backlog

A0.5 must convert this RFC into concrete schema or SPEC sections for:

- Canonical role registry and alias-resolution input.
- Role contract minimum fields.
- Shared handoff envelope.
- `planner-output`.
- `worker-contract`.
- `qa-contract`.
- `reviewer-verdict`.
- `flow-test-checklist`.
- `release-packet`.
- Typed failure statuses and event names.
- Phase-gate review inputs/outputs.
- Helper-extraction contract template.

Any downstream implementation issue that adds or changes a role, handoff artifact, or decision boundary must update the SPEC/schema source first, then implementation. Implementation cannot rely on a role behavior that exists only in assistant memory or issue prose.
