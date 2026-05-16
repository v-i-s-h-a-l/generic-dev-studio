---
name: Issue Comment Pipeline
schema_version: 1
description: Public-safe structured comment contract for GitHub issue and PR comments emitted by studio agents.
type: contract
---

# Issue Comment Pipeline

Studio agents that write public GitHub issue or PR comments must use the
`studio-comment:v1` contract. Comments are coordination breadcrumbs only; they
must never become the source of truth for chain state, issue scope, reviewed
plans, manifests, event logs, or worker summaries.

Canonical state stays in issue bodies, PR descriptions, chain manifests,
runtime state, event logs, reviewed phase artifacts, and completion summaries.
Public comments may link to those public surfaces or summarize their status,
but private reconstruction details stay in private runtime artifacts.

## Marker Syntax

Every structured public comment starts with a single HTML marker on the first
line:

```text
<!-- studio-comment:v1 kind=<kind> idempotency_key=<key> target=<issue|pr>:<number> source=<tool> -->
```

Rules:

- `studio-comment:v1` is literal and versioned.
- `kind` must be one of the supported values below.
- `idempotency_key` is required and must be stable for the logical comment.
- `target` must be `issue:<number>` or `pr:<number>`.
- `source` identifies the writer surface, usually `studio-comment`.
- Values use only letters, numbers, `.`, `_`, `:`, `/`, and `-`; spaces are
  not allowed inside marker values.

The marker is public metadata. It must not include local paths, host names,
private artifact paths, secrets, prompts, token counts, raw logs, or full
reviewer output.

## Supported Kinds

| Kind | Use |
|---|---|
| `chain-progress` | Compact progress recap for a chain or issue slice. |
| `chain-issue-started` | A chain runner started work on one issue. |
| `chain-issue-completed` | A worker completed local implementation for one issue. |
| `chain-issue-blocked` | Work halted with a public-safe blocker reason. |
| `chain-review` | A public-safe review verdict or review-gate status. |
| `chain-final-summary` | Final chain or PR-ready summary. |

Future kinds require updating this contract, the JSON schema, and
`scripts/studio-comment.sh` together.

## Idempotency Key Rules

The idempotency key identifies the logical public comment, not one process
attempt. It should be deterministic from stable public identifiers:

```text
<chain>:issue-<number>:<kind>
<chain>:pr-<number>:<kind>
```

Retry attempts, host names, local worktree names, timestamps, and private run
artifact paths must not appear in the key. A writer may update a matching
existing structured comment in a later slice, but it must not use a new key to
hide duplicate status for the same logical event.

## Body Shape

Structured comment bodies use public-safe sections:

```text
<!-- studio-comment:v1 kind=chain-issue-completed idempotency_key=centralized-comment-pipeline:issue-981:chain-issue-completed target=issue:981 source=studio-comment -->
### Summary
Issue #981 completed local implementation.

### Evidence
- bash -n scripts/studio-comment.sh: passed
- scripts/test-fixtures/980-comment-pipeline-writer/test-comment-pipeline-writer.sh: passed

### Next
Chain runner will integrate and close the issue after review.
```

`Summary` is required. `Evidence` and `Next` are optional but must remain
bounded and public-safe.

## Public-Safety Rules

Comments may mention only public-safe identifiers and abstract status:

- issue and PR numbers or URLs
- chain name
- stage, status, verdict, reason id, and gap kind
- run id when it is already part of public coordination
- artifact class, retention class, cleanup outcome, routing reason class, and
  executor role
- startup failure class, launch stage, and prompt boundary status

Comments must not include:

- local absolute paths or home-directory paths
- private runtime roots, worktree roots, or artifact paths
- raw prompts, private review output, raw logs, stack dumps, or secret material
- token totals, cache totals, velocity data, or private cost details
- machine names, node names, host auth paths, or user account paths
- proprietary source excerpts beyond public diff context

The shared writer performs a conservative pattern check, but callers remain
responsible for passing only public-safe content.

## Enforcement

`scripts/studio-comment.sh` is the only approved shell writer for public
studio issue/PR comments. `scripts/lint-studio-comments.sh --staged` blocks
new unstructured `issue comment` and `pr comment` GitHub CLI call sites outside
that writer and outside explicitly allowlisted legacy migration entries.
The same lint runs from the pre-commit hook, so new agent issue/PR comment
producers must route through the shared writer unless the operator is
intentionally migrating a legacy call site with the annotation below or the
explicit user-controlled bypass.

Per-line carve-out:

```text
# lint-studio-comments:allow next-line — <reason>
```

Emergency/debug bypass:

```text
STUDIO_BYPASS_COMMENT_STRUCTURE_LINT=1 git commit ...
```

The bypass prints an audit line and is user-controlled. Assistants must not set
it silently.

## Context Packet Reader

`scripts/issue-context-packet.sh` reads an issue body plus comments and writes a
bounded planning packet. It extends the writer contract by recognizing the same
first-line `studio-comment:v1` marker; it does not replace writer semantics or
make comments authoritative.

Use comment-aware planning when public issue comments contain decisions,
constraints, failures, acceptance changes, conflicts, or open questions that
would otherwise be missed by an issue-body-only plan. The manager front door is
`scripts/manager-plan-chain.sh --issue <n> --include-comments ...` for one
issue, or `scripts/manager-plan-chain.sh --issue-set <csv> --include-comments
...` for a related cluster. The equivalent router guidance is
`/dev-studio manager plan-chain ...` with the same `--include-comments`,
`--issue`, or `--issue-set` selectors. The resulting packet and sidecar are
planning evidence only; issue bodies, manifests, state files, event logs,
reviewed plan artifacts, and worker summaries remain authoritative.

Composite chains use the same rule for issue-sourced children: when the status
flow directs a child planning step and comments are needed, the child planner
uses the public-safe issue-context packet. Manifest-sourced children keep their
source-file planning path. The composite status/resume surfaces do not make
parent issue comments a manifest substitute.

Inputs:

- Live GitHub reads use `scripts/studio-gh.sh api` for the issue and paginated
  REST comments.
- Fixture or pre-fetched reads may pass `--issue-json` and `--comments-json`.

Outputs under `--out-dir`:

- `packet.md`: cited planner-facing Markdown with source issue, included comment
  range, decisions, constraints, failures, acceptance changes, conflicts, open
  questions, and provenance table.
- `packet.json`: machine-readable sidecar with issue refs, comment ids, urls,
  timestamps, author classification, marker metadata, duplicate/stale metadata,
  and extracted signal categories.
- `raw/issue.json` and `raw/comments.json`: local/private archive for audit only.
  Raw comments are not used as the direct planner prompt.

Author classification is intentionally conservative:

- `marked_agent`: comment starts with a valid `studio-comment:v1` marker.
- `legacy_unmarked_agent`: unmarked bot-shaped author.
- `human`: unmarked non-bot author.

Duplicate structured comments are detected by repeated `idempotency_key`; older
instances are marked stale with `superseded_duplicate_idempotency_key`. Comments
created after an issue's `closed_at` timestamp are marked `after_issue_closed`.
Private-path or secret-shaped content is excluded from extracted signals and
marked `private_or_secret_shaped_content_redacted` in the sidecar.
