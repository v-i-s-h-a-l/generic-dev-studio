---
name: Studio Summary Mode
description: End-of-task / end-of-session completion report. Summarizes what was done, what changed, verification, unresolved items, user-pending actions, and the next command.
type: mode-pack
schema_version: 1
budget_tokens: 1200
reads:
  - current conversation context
  - git status / git diff / git log when repo changes are involved
  - gh issue / gh pr state when GitHub work is involved
  - _shared/patterns/budget-telemetry.md when token usage is available
writes: []
---

# Mode: Summary

Reusable completion report for any studio task, PR, work-chain item, or session. Invoke directly when the user asks for "summary", "safe to end session", "what changed", "what was done", or "wrap this up".

This mode is composable: another mode can finish by applying this report shape instead of inventing its own ending.

## When to Use

- The user asks whether it is safe to end the session.
- A task, issue, PR, track item, or workflow chain just finished.
- The user asks what was done, what changed, what remains, or how to resume.
- A long-running mode needs a consistent final checkpoint.

Do not use this for ordinary progress updates while work is still in flight.

## Procedure

1. READ the completed scope: issue number, PR number, branch, workflow track, command, or explicit user request.
   Before: The user asks for a completion report or another mode has stopped.
   After: The response has one explicit scope.
2. CHECK evidence before claiming completion:
   Before: A completion claim would be made.
   After: Evidence has been read or the missing evidence is stated.
   - `git status --short`
   - relevant `git log --oneline -n 5`
   - `gh issue view` / `gh pr view` when GitHub state matters
   - test/build command results if they were run
3. RECORD automated work separately from user-pending work.
   Before: The scope includes elapsed time, decisions, blocked items, or follow-ups.
   After: User-pending actions are visible without counting as automation delay.
4. RECORD token usage from `_shared/patterns/budget-telemetry.md` when it is available in the host/session context; do not invent it.
   Before: The host/session exposes token data or the user asked for token data.
   After: Token data is included or explicitly marked unavailable.
5. PROCEED with the completion report using the format below.
   Before: Scope, evidence, pending work, and optional token data are known.
   After: The user can end, resume, or redirect without reconstructing context.

## Output Format

Use this exact section order. Omit a section only when it is genuinely not applicable.

```
Done:
- <completed outcome, not activity log>

Changed:
- <files, commands, modes, issues, PRs, branches, or workflow behavior changed>

Verified:
- <tests, checks, commands, reviews, or GitHub state checked>
- Tokens: <input/output/cache when available; "not available" only when the user asked for token data>

Not Done:
- <remaining work, blocked items, skipped tests, or user-pending decisions>

Next:
- <single most useful next action>
- Command: `<copyable command when one exists>`

Safe To End:
- Yes/No. <one sentence explaining why>
```

## Rules

- Lead with outcomes, not a transcript.
- Do not claim a task is complete without evidence from files, git, GitHub, or command output.
- Keep user-pending work separate from automation-active work.
- Include issue / PR numbers when present.
- Include the exact command for the next useful action when available.
- If verification was not run, say so plainly.
- If the repo or branch is dirty, say what is dirty and whether it blocks ending the session.

## Mode Combination

Any studio mode can end with "apply `summary`" to reuse this report. The combination convention is:

```
/studio <mode> ... + summary
```

This means: run the requested mode, then finish with the `summary` output format. If the user types only `/studio summary`, summarize the current task/session from available context.
