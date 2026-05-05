---
name: Completion Summary Contract
description: Shared user-facing completion summary shape for manager, worker, reviewer, and debrief paths.
type: contract
---

# Completion Summary Contract

When a role gives the user a task-completion conclusion, the final human note
uses this information architecture:

```text
We fixed/implemented <truthful outcome>.

Impact on user:
Behavior before:
Behavior after:
New behavior:

Operational closure:
PR/merge state:
Local sync state:
Worktree cleanup:
Derived data and stale artifacts:

Safe to end the session.
```

Labels may be adapted to the task type, but the summary must preserve the same
shape:

- Lead with `We fixed ...`, `We implemented ...`, or the closest truthful
  equivalent for review-only, blocked, or no-change work.
- Split user impact into before, after, and new behavior when the task changed
  user-visible behavior. If one field does not apply, say `Not applicable` and
  why in a short phrase.
- State operational closure explicitly: PR or merge status, local sync status,
  worktree cleanup, and derived-data or stale-artifact cleanup.
- End with `Safe to end the session.` only when merge or closure, local sync,
  required cleanup, and required artifact writes actually completed.
- If merge, sync, cleanup, verification, or artifact emission did not happen,
  replace the safe-close line with `Not safe to end the session yet:` followed
  by the remaining blocker or owner.

This contract governs user-facing conclusions only. Typed artifacts such as
worker summaries, debrief YAML, reviewer verdicts, release packets, and event
log entries remain the source of truth for automation.
