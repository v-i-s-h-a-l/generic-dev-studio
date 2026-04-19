# Usage Analysis Procedure

How generic-dev-studio observes itself. Runs **from this repo**, never from the project being analyzed (CLAUDE.md "Analysis sessions and privacy").

## When to run

- **Day 1 (now).** Don't wait for perfect telemetry. The current 16-event schema + debriefs + reviews + git log cover ~70% of useful signal. Every missed signal goes in the `## Wished I had` section and feeds future schema work (#11).
- **Recurring.** At roughly the end of each week the studio is in active use — or after any release that lands 10+ tasks. Frequency tightens if the prior pass surfaced a pattern that hasn't been addressed.
- **Ad-hoc.** After any incident, surprise, or regression where "what actually happened?" isn't obvious from memory.

## Inputs (read these in order)

| # | Source | Path | What it tells you |
|---|---|---|---|
| 1 | **Feedback inbox** | `~/.dev-studio/generic-dev-studio/feedback-inbox/<project>/*.md` | User-authored records of rule gaps, rule misses, bugs, ideas. Highest signal per token — already distilled, often with proposed designs. Read **first**. |
| 2 | Event log | `~/.claude/projects/<slug>/memory/events/*.jsonl` | Task lifecycle, review verdicts, dispatch events. Primary mechanical signal. |
| 3 | Debriefs | `~/.dev-studio/<project>/plans/chanakya-inbox/processed/*-debrief.md` | What Achilles wrote when the work landed. Look for patterns in "Key Learnings" + "Blockers". |
| 4 | Argus reviews | `~/.claude/projects/<slug>/memory/reviews/*.md` + `reviews/archive/` | Flag/block frequency by rule. Feeds REVIEW.md rule evolution. |
| 5 | Worker logs | `~/.dev-studio/<project>/.runtime/achilles-inbox/worker-*/worker.log` | Per-task timing, stuck states, rescue events. |
| 6 | Git log | `git log --first-parent --since=<window>` in the **target project**, not this repo | Time-to-merge, PR size distribution. Pair with event log for dispatch→merge latency. |

**Feedback-inbox first, always.** User-authored feedback records are the highest-signal input: they come pre-distilled, often include a proposed design, and carry severity judgments that events and debriefs can't express. A pass that skips feedback-inbox silently downgrades user-reported findings to re-derivable patterns and misses anything severity-high that hasn't yet manifested in event counts.

Ingestion is automatic (`scripts/ingest-feedback.sh`, wired to SessionStart + Chanakya Step 0F). The inbox should therefore be **empty or near-empty** on any analysis pass — unprocessed records mean ingestion hasn't fired (missing hook, cross-project sessions only, sanitization bail-out on a leaky record). Treat a non-empty inbox as a finding in its own right; investigate before proceeding with the rest of the pass.

Use `scripts/analyze-collect.sh <project-slug>` to gather mechanical stats in one shot (counts, duration medians, rule-hit frequencies). Manual reading of debriefs and reviews stays a human step — that's where the patterns live.

## Report template

Land reports at `~/.dev-studio/<project>/analysis/<YYYY-MM-DD>.md`. Private — never committed.

```markdown
# Usage analysis: <project> — <YYYY-MM-DD>
Window: <start> → <end>
Passes prior: <N>

## Tasks shipped
<count, sizes, median duration, rescue rate>

## Event-log summary
<counts per type; notable spikes or gaps>

## Review verdicts
<approved/flagged/blocked rates; which rules fire most>

## Friction points
<where the pipeline stalled: task_awaiting_user, merge_conflict, rescue, re-dispatch>

## Patterns worth promoting
<candidates for REVIEW.md rule tweaks, brief-template additions, skill-prose trims>

## Public issues to file
<one-line abstract-pattern summaries; each becomes a GitHub issue on generic-dev-studio>

## Wished I had
<events, data, or hooks that would have made this pass sharper — feeds #11 and future schema work>
```

Every section can be empty for a given pass. The `## Wished I had` section must exist — a pass that doesn't name at least one blind spot is probably not looking hard enough.

## Privacy discipline (hard stop)

Reports are private. Before lifting anything out of a report into a GitHub issue, commit message, or PR description:

- Strip task IDs, feedback-record IDs, debrief text, Slack channels, @mentions, project/feature/module names, build numbers, performance numbers, anyone's name.
- Rewrite as an abstract pattern: "Argus's secrets-in-diff rule false-positives on test fixtures ~30% of the time" — not "on 2026-04-15, Argus flagged real-creds.json in T0142 which was actually a fixture".
- Self-check: *if this text were posted to a competitor's Slack, would anything embarrassing or proprietary leak?* If yes, rewrite. If still leaky, keep it private.

See CLAUDE.md → "Analysis sessions and privacy" for the full split.

## Follow-ups

Actions fall into three buckets after a pass:

1. **Code/doc commits** — land on this repo (scoped rule edits, threshold tweaks, brief-template additions). Respect REVIEW.md tiers; auto-apply where allowed (CLAUDE.md "Auto-apply tiers").
2. **GitHub issues** — for patterns that need planning or discussion. Label with the theme (see THEMES.md).
3. **`## Wished I had` items** — feed the event-log blind-spot backlog (#11). Don't block the pass on wiring them; the capture is the point.
