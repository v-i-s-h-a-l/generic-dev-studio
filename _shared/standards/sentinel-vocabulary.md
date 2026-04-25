---
name: Sentinel Vocabulary
description: Authoritative set of sentinel verbs used at the start of every action step in skill procedures. No synonyms. Linter-enforced.
type: standard
schema_version: 1
---

# Sentinel Vocabulary v1

Every action step in a `## Procedure` block MUST start with one of these verbs (UPPERCASE in source, optionally bold in rendered output). The set is closed; synonyms are linter blocks. The discipline trades a small expressive cost for cross-model reading parity — `EMIT` always means "write a structured event", never "log", "print", "fire", or "send".

## Verbs

| Verb | Meaning | Typical object |
|---|---|---|
| `READ` | Load file or memory into the model's context | path, schema-document |
| `WRITE` | Persist content to disk | path, structured artifact |
| `RUN` | Execute a script, binary, or command | shell command, ledger writer |
| `CHECK` | Evaluate a condition; on result, branch via decision table | condition, exit code |
| `EMIT` | Append a structured event to the event log | event-name + payload |
| `RECORD` | Persist a non-event durable artifact (debrief, review verdict, snapshot) | artifact name |
| `STOP` | Halt the procedure cleanly; emit `agent_session_completed`; do not call any further step | — |
| `PROCEED` | Continue to the next numbered step (used in decision-table outcomes) | step number |
| `RETRY` | Re-attempt the same step, with explicit backoff | retry budget, backoff |
| `SKIP` | Jump past one or more steps to a labelled step | step number |
| `ESCALATE` | Surface to user / parent agent; capture context; await direction | recipient, context path |
| `BLOCK` | Refuse to proceed; emit a blocking event; exit non-zero | reason, event-name |

## Forbidden synonyms

The linter rejects these in step prefixes; replace with the canonical verb above.

| Synonym | Replace with |
|---|---|
| `output`, `dump`, `print`, `log`, `fire`, `send` (when meaning emit a structured event) | `EMIT` |
| `bail`, `abort`, `quit`, `give up` | `STOP` or `BLOCK` |
| `try`, `attempt`, `consider`, `perhaps`, `maybe` | imperative verb (no soft modals) |
| `note`, `mention`, `point out` | `RECORD` (if durable) or remove |
| `look at`, `inspect`, `examine` | `READ` or `CHECK` |
| `kick off`, `launch`, `invoke` (when meaning run a script) | `RUN` |
| `surface`, `raise`, `flag` (when meaning escalate to user) | `ESCALATE` |

## Soft modals (always blocked inside `## Procedure`)

`should`, `may`, `might`, `consider`, `perhaps`, `try to`, `if possible`, `we could`, `it would be good to`.

Soft modals encode optionality. Procedures are not optional; they are the contract. Replace with imperatives or move the discussion outside the procedure block.

## Pre/post verbs

`Before:` and `After:` declare invariants, not actions. They are noun-phrases; the verb space is open ("worktree exists", "lockfile is held", "event log has been swept since 0F"). Linter does not enforce a verb set on these lines, only that they are present per step.

## Versioning

Adding a verb to the sentinel set is a `schema_version` bump on the standard (since it changes what "valid grammar" means). Removing one is a major bump that requires migration.
