---
name: Chanakya Feedback
description: Full feedback lifecycle (review, archive, history, studio-feedback) excluding Slack ingestion (which lives in modes/ingest.md). Applies user-testing edits to the master plan and promotes verified records to per-build archive.
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md
snapshots: [briefs.json, feedback-inbox.json]
budget_tokens: 4000
reads:
  - plans/index.yaml                               # post-migration task + feedback index
  - plans/tasks/*.yaml                             # post-migration per-task artifacts (schema: _shared/schemas/task.md)
  - plans/rounds/*.yaml                            # post-migration round artifacts (schema: _shared/schemas/round.md)
  - plans/feedback/*.yaml                          # post-migration feedback artifacts (schema: _shared/schemas/feedback.md)
  - plans/user-testing.md                          # user-authored test-manifest surface (legacy shape, preserved through Phase 2.6)
  - plans/chanakya-master.md                       # legacy fallback until Commit H
  - feedback/active.md                             # legacy feedback index until Commit H
  - feedback/archive/**/*.md                       # legacy archive until Commit H
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
writes:
  - plans/tasks/<task-id>.yaml                     # task state bumps + follow-up task mint (state transitions per _shared/state-machines/task-lifecycle.md)
  - plans/feedback/<feedback-id>.yaml              # feedback state transitions per _shared/state-machines/feedback-lifecycle.md
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh after artifact writes
  - plans/user-testing-archive/<ts>.md             # archived test-manifest after processing
  - feedback/active.md                             # legacy active-list prune during Phase 2.6 transition
  - feedback/archive/build-<N>.md                  # legacy archive append during Phase 2.6 transition
  - feedback/incoming/F<nnn>.md                    # legacy staging-file removal during Phase 2.6 transition
  - feedback-inbox/*/processed/*                   # studio-feedback ingestion move target
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Mode: Review-Feedback (`/chanakya review-feedback`)

Parse the user's edits to `user-testing.md` and apply them to the master plan.

Snapshots: `snapshots/briefs.json` for task lookup (5-min freshness — fall back to `chanakya-master.md` when stale). `snapshots/feedback-inbox.json` is checked when the feedback lifecycle is involved (fallback: read `feedback/active.md` directly).

## Step 1 — Read the manifest

Read `~/.dev-studio/<project>/plans/user-testing.md`. Parse each `## T<id> — <Title>` section.

## Step 2 — Classify each case within each task

For each case under each task:
- `- [x]` (checked) → pass
- `- [ ]` with non-empty `Notes:` → fail (treat the note as a problem statement)
- `- [ ]` with empty `Notes:` → skipped (user hasn't tested it yet)

## Step 3 — Roll up per task

- **All cases passed** (every case is `- [x]`) → transition the task's `state` from `merged`/`user-verifying` to `verified` per `_shared/state-machines/task-lifecycle.md`.
- **Any case failed** (unchecked with notes) → leave the task state untouched (it stays `merged`/`user-verifying`) and mint one follow-up task per failure as a fresh `plans/tasks/<task-id>.yaml`:
  - Mint a UUIDv7 `id`.
  - Human-readable title: "Fix <parent-task-title> — <first sentence of the note>".
  - Body content from the note lives in the brief once Brief mode runs against the follow-up; the task artifact itself carries only `title`.
  - Priority is derived by Chanakya's downstream mode (the task schema does not encode priority in `task@1.0.0`); surface "P0" in the user-visible report when the note language matches blocker/crash/data-loss.
  - Initial `state: proposed`; history seeded with `from: null, to: proposed, actor: chanakya`.
  - `links: {brief: null, debrief: null, reviews: [], release: null, feedback: [<feedback-id of the originating manifest entry, if any>]}`.
- **Mixed passed + skipped** (no failures, but not everything checked) → leave the parent task state untouched; the manifest will still include it next time.

When a manifest row resolves from a previously-ingested feedback record, also transition that feedback's `state` to `linked` (add the failing task's UUIDv7 to `linked_tasks`) or to `resolved` (set `resolved_by: <task-id>`, `resolved_at: <ts>`) per `_shared/state-machines/feedback-lifecycle.md`.

## Step 4 — Write changes

For each task/feedback transition above, update the corresponding `plans/tasks/<task-id>.yaml` / `plans/feedback/<feedback-id>.yaml`: bump `updated_at`, append the `history:` entry (task artifacts), and emit `task_state_changed` / `feedback_state_changed` events via `scripts/write-event.sh`. Regenerate `plans/index.yaml` via `scripts/rebuild-index.sh`.

**Phase 2.6 transition note:** also update `chanakya-master.md` (legacy status mutations + new follow-up task rows) until Commit H cutover.

## Step 5 — Archive the manifest

Move the processed manifest to `~/.dev-studio/<project>/plans/user-testing-archive/<YYYY-MM-DD-HH-mm>.md`. This preserves the user's historical feedback and ensures `/chanakya test-manifest` can regenerate cleanly from scratch (no dirty-state guard trip next time).

## Step 6 — Report

"Processed user-testing.md:
 - T013 → verified
 - T014 → verified
 - T015 → 2 follow-ups created (T031, T032)
 
Archived to user-testing-archive/2026-04-15-14-30.md. Generate a fresh manifest when more tasks complete."

---

# Mode: Feedback-Archive (`/chanakya feedback-archive [--build N] [--notify-slack] [--dry-run]`)

Promote `verified` records (or `wontfix`) to `archive/build-<N>.md`, apply asset retention, optionally notify Slack.

## Steps

1. **Select.** Gather all F-records with `status ∈ {verified, wontfix}` and (if `--build N`) `fixed_build == N`. Without `--build`, archive everything eligible.
2. **Write archive.** For each selected F-id, append its full record block to `archive/build-<N>.md` (create the file if absent; order by F-id). Use `fixed_build` as `<N>` unless the record is `wontfix` (use `reported_build` in that case).
3. **Video retention.** If `video_path` is a live file: write `(deleted — <filename>, <one-line description from original_message>)` **into the archive record first**, then `rm` the file. Update active.md reference similarly.
4. **Screenshot retention.** Do **not** delete screenshots here — they expire 7d post-archive via the Step 0D janitor. Record `archived_date: <today>` so the janitor can compute the 7-day mark.
5. **Remove from active.** Delete the F-record row from `feedback/active.md` and its staging file `feedback/incoming/F<id>.md`.
6. **Regenerate indices.** For each reporter appearing in the archived set, regenerate `feedback/reporters/<slug>.md` by scanning active + archive.
7. **Root-cause promotion.** For each `root_cause` label appearing on 2+ records across archive, ensure `feedback/root-causes/<pattern>.md` exists. On first promotion emit:
   ```json
   {"ts":"…","agent":"chanakya","event":"root_cause_promoted","task":"<pattern>","data":{"instances":["F001","F009"]}}
   ```
8. **Slack notify** (if `--notify-slack`, off by default):
   - For each archived record whose `source` starts with `slack-thread:` or `slack-dm:`:
     - `reactions.add` with `name=white_check_mark` to the original message (bot token).
     - Post a threaded reply:
       > "Fixed in build <fixed_build> (commit <fix_commit>). Thanks <reporter>!"
     - Respect the existing 5-writes/min throttle from `project_slack_list_sync.md`.
     - If the write fails, log and continue — archive mutation is already durable.
9. **Emit per record:**
   ```json
   {"ts":"…","agent":"chanakya","event":"feedback_archived","task":"F<id>","data":{"build":<N>,"reporter":"<name>","linked_task":"T<id>"}}
   ```
10. **Report.** "Archived 4 records to `archive/build-3141.md` (F001, F002, F005, F007). Notified Slack: 3. Screenshots scheduled for 7d deletion on 2026-04-25."

## `--dry-run`

Print the selected F-ids and proposed archive file path. Do not write, delete, or notify.

## Auto-trigger

`feedback-archive` is called implicitly at the end of `compact` (archive eligible records before compacting) and at the end of `review-feedback` (when a record's linked task moves to `verified`). Both implicit calls run **without** `--notify-slack` — the user runs it explicitly when they want Slack replies.

---

# Mode: Feedback-History (`/chanakya feedback-history [--reporter name] [--module name] [--root-cause pattern]`)

Search active + archive. Exactly one filter at a time (if multiple passed, AND them).

## Steps

1. Walk `feedback/active.md` (rows), `feedback/incoming/*.md`, `feedback/archive/build-*.md`.
2. Match against the filter(s).
3. Print a table:

```
| F-id | Reporter | Source | Module | Build (reported→fixed) | Status | Linked Task | Location |
|------|----------|--------|--------|------------------------|--------|-------------|----------|
| F001 | @pranjali | slack-list:… | Recipe&Transforms | 3133→3135 | verified | T165 | archive/build-3135.md |
```

4. If `--root-cause <pattern>` is passed, also print the contents of `feedback/root-causes/<pattern>.md` at the top.

No writes. Pure read.

---

# Mode: Studio-Feedback (`/chanakya studio-feedback` or conversational "capture this as feedback")

Capture feedback about the studio itself — Chanakya/Achilles/Argus/scripts, brief-template defects, rule misses, workflow friction, MCP or harness issues observed while using the studio. **Distinct from the project-feedback family** (`feedback-archive`, `feedback-history`, `ingest-*`, `report-*`), which handles stakeholder/tester reports about the product being built.

## Triggers

- User types `/chanakya studio-feedback`.
- User says conversationally: "capture this as feedback", "file feedback", "save this as feedback", or similar.

## Canonical inbox path

Always write to the per-project inbox under the studio's own project slug:

```
~/.dev-studio/generic-dev-studio/feedback-inbox/<source-project>/<ts>-<kind>-<slug>.md
```

- `<source-project>` = `resolve_project()` result of the session where this mode runs (e.g. `turnip-ios`, `generic-dev-studio`). Groups feedback by where it was noticed.
- `<ts>` = `YYYYMMDD-HHMMSS` UTC.
- `<kind>` = `bug` | `friction` | `idea` | `rule-miss`.
- `<slug>` = ≤40 chars, lower-kebab-case, derived from the session description.

Example: `~/.dev-studio/generic-dev-studio/feedback-inbox/turnip-ios/20260418-203000-bug-worker-rc0-silent-stuck.md`

Create parent dirs with `mkdir -p` — no setup required. The path is hardcoded because the point of this mode is to route every session's feedback to the **same canonical location** (earlier sessions scattered to `/tmp`, `~/.claude/...`, etc. — the hardcoded path is what prevents scatter).

## File format

```
---
ts: <ISO-8601 UTC>
session: <one-line what the user was doing, ≤20 words>
source_project: <slug>
kind: bug | friction | idea | rule-miss
severity: low | med | high
scope: generic-dev-studio | upstream | work-project
---
<body — what happened, why it matters, repro or root cause if known, proposed fix if obvious>
```

## After write

Print one line confirming the write path, e.g. `Wrote feedback to ~/.dev-studio/generic-dev-studio/feedback-inbox/turnip-ios/<file>.md — will be ingested on next generic-dev-studio session.`

Do not require the user to do anything else. Do not paste, do not copy.

## Ingestion (generic-dev-studio session only)

When the current session's project slug is `generic-dev-studio`, Step 0 scans `~/.dev-studio/generic-dev-studio/feedback-inbox/*/` for new `.md` files **outside** of `processed/` subdirs. For each file:

1. Append verbatim to `~/.dev-studio/generic-dev-studio/analysis/<date>.md` (always, private).
2. Decide scope from the file's `scope:` frontmatter:
   - `generic-dev-studio` → offer to file a sanitized GitHub issue via `gh issue create`.
   - `upstream` → surface the record, ask user where to file (Playwright MCP repo / claude-code issue tracker / etc.).
   - `work-project` → no public filing; private analysis only.
3. Move the file to `<source-project>/processed/<filename>`.

The ingestion step is a no-op in sessions outside `generic-dev-studio` — files just accumulate in `feedback-inbox/<source-project>/` until the user next opens a generic-dev-studio session.
