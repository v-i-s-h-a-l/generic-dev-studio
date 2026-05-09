---
name: Task Graph
description: Deterministic dependency graph synthesized from a normalized requirement packet before worker scheduling.
type: contract
---

# Task Graph

`scripts/prd-task-graph-synthesize.sh` reads the Markdown requirement packet
from `_shared/contracts/requirement-packet.md` or a structured Markdown source
with numbered component headings, then writes a serializable JSON graph for
scheduler planning. When a packet has a readable filesystem path in its
`Source` metadata and the packet itself has no component headings, the
synthesizer reads that source path to recover the component axis. The graph is
a pre-executor artifact: it does not dispatch workers, choose review
escalation, or mutate issues.

## Shape

The graph contains:

1. `source` - packet title, source label, SHA-256 fingerprint, and generator
   version.
2. `nodes` - deterministic task nodes with stable IDs derived from packet item
   IDs (`T-R001`, `T-M001`, and so on).
3. `edges` - dependency edges, sorted by source and target.
4. `ready_node_ids` - nodes whose dependencies are already satisfied.
5. `validation` - graph validity, missing dependency references, parallel write
   races, packet conflicts, and unresolved missing details.

## Node Rules

- Explicit requirements (`R###`) become `task` nodes.
- Missing details (`M###`) become `shared_prerequisite` nodes and every task
  depends on them. This makes unresolved intake gaps visible before execution.
- Packet conflicts (`C###`) are validation blockers.
- Text references such as `depends on R001`, `after R001`, or `requires R001`
  become dependency edges.
- Backticked paths or resources in lines that say `write`, `modify`, `touch`,
  `update`, `create`, `emit`, or `produce` become `write_resources`.
- Consistent Markdown component headings such as `### 1. <Title>` become the
  task axis when present. Open-question sections become unresolved missing
  details instead of tasks.
- Task nodes with no `write_resources` are invalid unless they explicitly carry
  `allowed_paths_unscoped: true` and an `allowed_paths_unscoped_justification`.

## Validation

Validation is deterministic and runs before execution:

- A dependency reference to an item not present in the graph is reported in
  `validation.missing_dependencies`.
- Two independent nodes that write the same resource are reported in
  `validation.parallel_write_races`.
- Missing details and conflicts keep `validation.status` at `invalid` unless the
  caller passes `--allow-missing-details`.
- Empty allowed paths and fragment-shaped labels keep `validation.status` at
  `invalid`.

## Non-Goals

- No worker execution.
- No review escalation policy.
- No model inference beyond lexical signals preserved in the requirement packet.
