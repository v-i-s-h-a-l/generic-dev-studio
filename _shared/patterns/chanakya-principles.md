---
name: Chanakya Principles
description: Cross-cutting invariants every Chanakya mode inherits. Behavior contract extracted from the pre-router SKILL.md. Event-emission specifics live in contracts/event-emission.md; this file references them.
type: reference
---

# Chanakya Key Principles

Every Chanakya mode pack inherits these invariants. Modes do not restate them; they reference this file.

1. **Never sit idle.** After every action, suggest the next step. The user approves or redirects.
2. **Briefs are self-contained.** Inline everything — Figma specs, code paths, constraints. Workers must not need MCP access or other files.
3. **Persistent state.** Always read before writing. The master plan and briefs survive across sessions.
4. **Confirm only for consequential writes.** Gate on user confirmation before: (a) external publishing (Slack sync write), (b) first-time master plan creation when no existing plan is present, (c) destructive config overwrites (`--configure` replacing existing constants). Routine brief and plan updates triggered by an explicit sub-command run without a gate.
5. **Parallel-first.** Default to recommending parallel execution. Only serialize when there are real dependencies.
6. **File overlap awareness.** During brief generation, check for conflicts with in-progress tasks.
7. **Learnings compound.** Worker debriefs feed into project memory. Knowledge accumulates across features.
8. **`done` ≠ `verified`.** Never close a feature until the user has signed off via `review-feedback`. Surface `done` tasks in status reports.
9. **Never auto-regenerate the test manifest.** It is user-driven; `test-manifest` runs only on explicit command, and refuses to clobber unreviewed edits unless `--force` is passed.
10. **Build debt is automatic.** Step 0 updates the counter from every debrief, auto-files TBUILD at warn@6, blocks at warn@12, files P0 fix tasks from red build checks. No user confirmation needed; the banner keeps the user informed.
11. **Fully automated.** Build-debt actions (counter updates, TBUILD filing, threshold transitions, janitor cleanup, closing TBUILD on green) never prompt the user. The banner is informational only.
12. **Test-flow rounds are immutable.** Once written, a round file is never silently overwritten — only `--force` allows it. Rounds accumulate as a historical record of testing quality over time.
13. **Test-flow is independent of review-feedback.** `test-flow` does not trigger `review-feedback`. The user reads it, tests, then uses `--promote` to bridge into `review-feedback`, or reports findings via `/chanakya intake`. The two test paths (`test-manifest` and `test-flow`) coexist without interference.
14. **Performance baselines are opportunistic.** Perf data flows from debrief `## Performance` / `## Key Learnings` into test-flow `Perf baseline:` fields. If no debrief perf data exists, the first round's `Timing:` entry becomes the baseline for future diffs. Never block test-flow generation on missing perf data.
15. **Event-driven follow-ups are automatic.** When `review_flagged` events appear in the event log, Chanakya auto-files follow-up tasks without user confirmation. This is not subject to the confirmation rule (#4) — it's a scoped, non-destructive file write.
16. **Event log is a first-class artifact.** Read it on every sweep (Step 0E). The offset marker prevents re-processing. Do not skip event log processing even when the inbox is empty. Emission rules — producer tagging, idempotency keys, atomicity — live in `_shared/contracts/event-emission.md`.
17. **Compact sweeps artifacts by default.** The `--sweep-artifacts` flag is on unless explicitly disabled. This keeps `/tmp/` and `reviews/` clean without user action.

## Task Status Lifecycle

```
pending  →  briefed  →  in-progress  →  done  →  verified
                                           ↘  needs-review  →  (back to in-progress)
```

- **`pending`**: task exists, no brief yet.
- **`briefed`**: brief written, ready for Achilles.
- **`in-progress`**: Achilles has claimed it.
- **`done`**: Achilles merged. Not yet user-verified.
- **`verified`**: user has manually tested and signed off via `/chanakya review-feedback`.
- **`needs-review`**: debrief flagged issues; requires revisit.

`done ≠ verified`. Tasks in `done` appear in the next user-testing manifest until the user verifies or files feedback. Completed features (see Post-Feature Wrap-Up) require all tasks to reach `verified`, not just `done`.

The authoritative state-machine (10+ states, transitions with preconditions) lives in `_shared/state-machines/task-lifecycle.md`; the 5-state view above is the user-facing summary.

## Session-completion event (every Chanakya mode)

At the end of any Chanakya session — regardless of mode — emit `agent_session_completed` per the emission contract in `_shared/contracts/event-emission.md`. The event carries `{mode, duration_s, files_read, files_written}` and (when available) `tokens` + `cost_usd` per `_shared/patterns/budget-telemetry.md`.

For task-specific modes (e.g. `brief T001`), use the task ID in the `task` field; for system-scope sessions, use `""`.
