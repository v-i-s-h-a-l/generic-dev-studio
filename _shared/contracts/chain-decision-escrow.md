---
name: Chain Decision Escrow
schema_version: 1
description: Private-runtime records for low-risk defaults chosen while autonomous studio chains continue.
type: contract
---

# Chain Decision Escrow

Autonomous studio chains use `chain-decision-escrow` when the runner or a worker makes a low-risk assumption/default and continues instead of blocking the whole run. This is not a halt record: it exists to make the decision visible and reviewable.

Formal validation lives in `_shared/contracts/chain-decision-escrow.schema.json`:

```bash
scripts/validate-contract.sh chain-decision-escrow <file>
```

## Required Fields

Every escrow record includes:

| Field | Meaning |
|---|---|
| `decision` | Human-readable decision being escrowed. |
| `default_chosen` | The default the automation applied. |
| `rationale` | Why continuing was safe enough. |
| `affected_artifacts` | Files, summaries, or runtime artifacts affected by the default. |
| `rollback_path` | How to reverse or amend the decision. |
| `review_deadline` | RFC3339 deadline after which the decision is no longer silently sticky. |

Escrowed decisions are sticky on `--resume <run_id> --yes` until the review deadline or explicit human override. Summaries may embed compact escrow entries or references in `assumptions_escrowed` and `decisions_made`; full records remain private runtime artifacts.

## Surfacing

Phase outcomes and final digests should include escrow summaries so the operator can review defaults without reading every worker artifact. The public-safe form is the decision, chosen default, affected artifact names, and review deadline.
