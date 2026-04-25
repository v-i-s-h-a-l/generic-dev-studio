---
name: Studio Analyze
description: Sweep a project's event-log shards + studio-feedback inbox to surface usage patterns, write a private detailed report, and distill scrubbed public patterns to GH issues. Canonical surface for "analyze logs and feedback for studio from <project>". Distinct from `ingest` (single-input classify); analyze is a queue/log sweep.
type: mode-pack
budget_tokens: 1200
snapshots: []
reads:
  - ~/.dev-studio/<project>/events/*.jsonl (daily event-log shards, ≥ 2026-04-17)
  - ~/.dev-studio/<project>/event-log.jsonl + events.jsonl (aggregate; verify canonical)
  - ~/.dev-studio/<project>/analysis/*.md (prior reports; trend baseline)
  - ~/.dev-studio/<project>/archive/ (debriefs)
  - ~/.dev-studio/generic-dev-studio/feedback-inbox/<source>/*.md (studio-feedback; processed/ excluded)
writes:
  - ~/.dev-studio/<project>/analysis/<today>.md (private, never committed)
  - GitHub issues on generic-dev-studio (scrubbed abstract patterns only)
  - studio-consolidation/parking-lot.md (if arc active; append-only)
---

# Mode: Analyze (Studio)

Fired when the user wants to **sweep** a project's studio-feedback inbox + event logs and turn the result into actionable patterns. Not for capturing a single thought (that's `ingest`); not for plan-vs-memory drift (that's `audit`).

Canonical phrasings:
- "analyze logs and feedback for studio from \<project\>"
- "what patterns are showing up in turnip-ios this week?"
- "sweep the studio-feedback inbox"
- `/studio analyze [<project>] [--since <date>]`

## Scope guard (read first)

This mode runs **from `generic-dev-studio` cwd**. The project being analyzed (default: most recently active under `~/.dev-studio/`, or arg) is data, not code. Never read or write inside the user's project repo. All output paths are under `~/.dev-studio/**` or this repo's tree.

Studio-feedback ≠ chanakya feedback. The two queues are disjoint:

| Queue | Path | Owner |
|---|---|---|
| Studio feedback (this mode) | `~/.dev-studio/generic-dev-studio/feedback-inbox/<source>/` | studio router |
| Chanakya project feedback | `~/.dev-studio/<project>/feedback/` | `/chanakya` skill |

If the user is in `generic-dev-studio` cwd asking about "feedback" or "logs", they mean the studio queue. Never silently fall through to the chanakya queue — surface the distinction and ask if intent is unclear.

## Step 1 — Resolve target project

```bash
# Default: most recently active per ~/.dev-studio/<project>/events/<latest>.jsonl mtime.
# Override: argument or STUDIO_ANALYZE_PROJECT env var.
```

Print the resolved project + window before reading anything. The user can redirect.

## Step 2 — Sweep the inputs

Three parallel reads:

1. **Studio-feedback inbox** — `~/.dev-studio/generic-dev-studio/feedback-inbox/<source>/`. Classify each non-`processed/` file:
   - Already-ingested (issue # in body / processed-marker) → skip.
   - Well-formed pending → list for re-ingest pass.
   - **Skipped (missing scope/kind frontmatter)** → surface explicitly. Do not silently drop.
2. **Event logs** — `~/.dev-studio/<project>/events/*.jsonl` shards, bounded `--since` (default 2026-04-17 per memory rule on log provenance). Group by event-type, count, extract notable patterns (repeated failures, spikes, dual-write partials, R10 hits, Argus blocks).
3. **Prior analysis reports** — `~/.dev-studio/<project>/analysis/*.md`. Read titles + key-findings sections only, not full bodies. Use as trend baseline ("this pattern was already flagged on \<date\>" → don't refile).

If any input is missing or empty, say so plainly. An empty studio-feedback queue is a valid finding ("queue empty since \<date\>"), not a stop condition.

## Step 3 — Classify findings (four buckets)

Per CLAUDE.md §Analysis sessions and privacy:

| Bucket | Output | Visibility |
|---|---|---|
| Detailed citations (record IDs, exact event sequences, project-specific context) | `~/.dev-studio/<project>/analysis/<today>.md` | **Private, never committed** |
| Distilled abstract patterns (scrubbed, actionable) | GH issues on `generic-dev-studio` | Public |
| Direct rule tweaks (auto-apply tier per CLAUDE.md) | edit `REVIEW.md` / `RELEASES.md` / `CLAUDE.md` / `THEMES.md` in-place | Public |
| Parking-lot candidates (arc-relevant, defer synthesis) | append to `studio-consolidation/parking-lot.md` | Public |

## Step 4 — Privacy scrub before any public output

Self-check (per CLAUDE.md): *if this text were posted to a competitor's Slack, would anything embarrassing or proprietary leak?*

Strip task IDs, feedback-record IDs, debrief text quoted verbatim, Slack channel names / @mentions, commit messages or branch names from the work project, file paths revealing proprietary architecture, build numbers, TestFlight versions, feature names, anyone's name, performance / velocity numbers.

If a pattern can't be cleanly anonymized, route it to the **private report** instead of a public issue. Better silent than leaky.

## Step 5 — Act + confirm

- Private report → write `~/.dev-studio/<project>/analysis/<today>.md`. Append if today's file already exists. Never `git add`.
- Public issues → `gh issue create --label <enhancement|bug|polish>` per CLAUDE.md §Backlog. One issue per distinct pattern; do not lump.
- Rule tweaks → in-place edit + commit message `review: <one-liner>` (auto-apply tier).
- Parking-lot → append entry with date + rationale.

End with a 2–4 line summary in chat: *"Swept N feedback items (M pending, K skipped) and X events from \<project\>. Filed P issues, wrote private report at \<path\>, applied Q rule tweaks."*

## Skipped-record handling

When the inbox sweep surfaces files the ingest script skipped (missing frontmatter), do **not** auto-fix silently. Show the user the file path + the missing field, ask whether to:
- (a) add the YAML frontmatter inline (default proposal),
- (b) leave for manual classification,
- (c) extend `scripts/ingest-feedback.sh` to tolerate the heading form (rule change, ask-tier).

Never delete a skipped record without user consent.

## Never

- Do not read inside the user's project source repo (only `~/.dev-studio/<project>/`).
- Do not commit `~/.dev-studio/**` paths to this repo (private analysis stays private).
- Do not file public issues that contain raw quotes from debriefs / feedback bodies.
- Do not duplicate findings already in prior `analysis/*.md` — cite + extend, don't refile.

## Fixture

`tests/mode-packs/studio/analyze.yaml` — subagent must correctly route to private vs public output, refuse to dispatch to chanakya queues, surface skipped records explicitly, and apply the privacy scrub before any `gh issue create`.
