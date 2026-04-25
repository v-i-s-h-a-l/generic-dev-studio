---
name: Chanakya Sync-Slack
description: Sync a Slack Lists bug tracker with the Chanakya master plan — Status, Dev Notes, Fixed in Build. Token + project bootstrap flags included.
type: mode-pack
schema_version: 1
transition_notes: _shared/patterns/dual-write-transition.md   # YAML counterpart for `sync.slack_last_synced` lands in Commit G; legacy-only write is waived until then (structural partial, not a drift).
snapshots: [briefs.json]
budget_tokens: 3500
reads:
  - plans/index.yaml                               # post-migration task index (for Slack-row cross-ref)
  - plans/tasks/*.yaml                             # post-migration per-task artifacts
  - plans/releases/*.yaml                          # post-migration release artifacts (build numbers, TF tags)
  - plans/chanakya-master.md                       # legacy fallback until Commit H
  - .runtime/state/chanakya-snapshots/briefs.json
  - feedback/active.md                             # reminders table (append target below)
writes:
  - plans/chanakya-master.md                       # legacy: Slack-status-last-synced writeback (until Commit G emits YAML)
  - feedback/active.md                             # append ingest-reminder rows
---

# Mode: Sync-Slack (`/chanakya sync-slack [--list <id>] [--build <number>]`)

Sync a Slack Lists bug tracker with the Chanakya master plan. Reads task statuses from the plan, writes Status + Dev Notes + Fixed in Build back to the Slack list. Designed to run after every TestFlight build upload.

Snapshots: `snapshots/briefs.json` for the task→Slack-row cross-reference pass (5-min freshness; post-migration fallback is `scripts/query-plans.sh --kind=task`, with a full `chanakya-master.md` scan still honored during Phase 2.6 transition).

## Configuration

All project-specific constants are in the project memory file `project_slack_list_sync.md`. Read it at mode entry for:
- List ID, column IDs, status option IDs, GitHub repo URL, stakeholder handles

**Bot token:** Read from `~/.claude/secrets/slack-bot-token` (single-line file, chmod 600). This token is cross-project (one Slack app) and does NOT live in per-project memory.

If `~/.claude/secrets/slack-bot-token` is missing, halt with:
> "Run `/chanakya sync-slack --configure-token` to set up the Slack bot token."

If `project_slack_list_sync.md` is missing, halt with:
> "Run `/chanakya sync-slack --configure` to set up project Slack constants."

## Flags

| Flag | Purpose |
|------|---------|
| `--list <id>` | Override default list ID. Schema discovery runs fresh for new lists. |
| `--build <number>` | Current TestFlight build number. Used for "Fixed in Build" column and Dev Notes entries. If omitted, read from latest `Bump build number` commit in git log. |
| `--configure-token` | Bootstrap: prompt for the Slack bot token once and write it to `~/.claude/secrets/slack-bot-token` (chmod 600). Creates `~/.claude/secrets/` dir (chmod 700) if missing. Cross-project — run once globally. |
| `--configure` | Bootstrap: interactively populate `project_slack_list_sync.md` in project memory with list ID, column IDs, status option IDs, repo URL, and stakeholder handles. |

## `--configure-token` mode

When `/chanakya sync-slack --configure-token` is invoked:

1. Create `~/.claude/secrets/` if it doesn't exist: `mkdir -m 700 -p ~/.claude/secrets/`
2. Ask the user: "Paste the Slack bot token (xoxb-...):"
3. Write the token to `~/.claude/secrets/slack-bot-token`: `printf '%s' '<token>' > ~/.claude/secrets/slack-bot-token && chmod 600 ~/.claude/secrets/slack-bot-token`
4. Verify: read back the file and confirm it starts with `xoxb-`.
5. Report: "Slack bot token saved to ~/.claude/secrets/slack-bot-token (chmod 600). Run `/chanakya sync-slack --configure` to set up project list constants."

## `--configure` mode

When `/chanakya sync-slack --configure` is invoked:

1. Check if `project_slack_list_sync.md` already exists in project memory. If yes, show current values and ask: "Update existing config? (y/n)"
2. Prompt for: List ID, column IDs (Status, Dev Notes, Fixed in Build, Reported in Build), status option IDs (Not started, In progress, Blocked, Done), GitHub repo URL, stakeholder handles (e.g., `daksh@`).
3. Write to `~/.claude/projects/<project-memory-dir>/memory/project_slack_list_sync.md` using the standard memory frontmatter format.
4. Report: "project_slack_list_sync.md written. Run `/chanakya sync-slack` to sync."

## Step 1 — Read current state

1. Fetch all rows: `GET slackLists.items.list?list_id=<id>&limit=50`
2. Collect all tasks with a `Slack row:` field. Post-migration: `scripts/query-plans.sh --kind=task --has=slack_row` over `plans/tasks/*.yaml`. Legacy fallback: scan `chanakya-master.md`.
3. Parse each row: extract Issue text, current Status, current Dev Notes content, current Fixed in Build, Reported in Build, row_id.

## Step 2 — Determine build number

If `--build` provided, use it. Otherwise:
```bash
git log --oneline --grep="Bump build number" -1
```
Extract the number from the commit message.

## Step 3 — Cross-reference and compute updates

For each Slack row with a linked Chanakya task:

**Status mapping** (option IDs from `project_slack_list_sync.md`):

| Task status | Slack Status |
|-------------|-------------|
| `verified` | Done |
| `done` (all acceptance cases pass in latest round) | Done |
| `done` (partial — some cases still fail) | In progress |
| `in-progress` or `briefed` | In progress |
| `pending` with no brief | Not started |
| blocked on dependency/PRD | Blocked |

**Dev Notes (append-only):**

1. Read existing Dev Notes rich_text from the row.
2. Build a new `rich_text_section` for the current build:
   ```
   Build <NUMBER>: <status summary>. <commit link if fixed>
   ```
   - Bold the `Build <NUMBER>:` prefix via `{"style": {"bold": true}}`
   - If the task has fix commits AND they're in this build (check via `git branch --contains <sha>`), append commit links as `{"type": "link", "url": "<github_url>", "text": "<sha[:7]>"}`
   - Status summary is one sentence: what changed since last sync. Examples:
     - "Fixed. Verified round 3." + commit link
     - "Core fix landed. Edge case pending — module re-entry loses selection (T184, P1)."
     - "No fix yet. Pending clarification from product team."
     - "Regressed by T027 crop overlay. Re-investigation needed (P0)."
3. Append the new section to existing elements. Never overwrite previous entries.

**Fixed in Build:**
- Set to `<build number>` when status transitions to Done for the first time.
- Once set, never overwrite (first-fix build is the reference).

## Step 4 — Guard: detect manual edits

Before writing each row, compare:
- Slack's current Status vs. what Chanakya last wrote (tracked via `Slack status (last synced):` in the task's master plan entry).
- If they differ (daksh@ manually changed it), skip the Status write and report: "Row <id> status diverged: Chanakya expected 'In progress', Slack shows 'Done'. Skipping — daksh@ may have verified independently."
- Still write Dev Notes (append-only is safe regardless).

## Step 5 — Reverse sweep: ingest new rows

For any row in the Slack list that does NOT have a matching task in the master plan:
1. File a new T-task (same logic as Intake Step 1).
2. Set `Slack row: <list_id> / <row_id>` on the new task.
3. Report: "New row from daksh@: '<issue text>' — filed as T186."

## Step 6 — Write updates

Batch all cell updates into a single `slackLists.items.update` call (or split into chunks of 20 cells if >20).

API shape per cell:
```json
{
  "row_id": "<row_id>",
  "column_id": "<col_id>",
  "select": ["<option_id>"]       // for Status
  // OR
  "rich_text": [...]              // for Dev Notes, Fixed in Build
}
```

## Step 7 — Update master plan

For each synced row, update the task's `Slack status (last synced):` field with the new status and timestamp.

## Step 8 — Report

Print a summary table:

```
Slack List <list_id> — Sync for Build 3137

| Bug                              | Status       | Fixed in | Dev Notes update |
|----------------------------------|-------------|----------|-----------------|
| Compare white screen after flip  | ✅ Done      | 3135     | (no change)     |
| Undo shows stale selection       | 🔄 In prog  | —        | Build 3137: T184 fix landed. |
| Text doesn't get added           | ✅ Done      | 3137     | Build 3137: Fixed. abc123f |

New rows ingested: 0
Manual edits detected: 0
```

## Integration with push-tf

When Chanakya processes a TestFlight release debrief (Step 0B2 of the review mode), after tagging tasks with `TF-<build>`, Chanakya **auto-runs** the full Sync-Slack computation (Steps 1–5) without waiting for user input. The only user gate is a confirmation prompt before the Slack write (Step 6):

> "Slack sync ready for build <N>:
> - 2 rows → Done (T129, T126)
> - 5 rows → In progress (T110, T124, ...)
> - 1 new row ingested as T186
> 
> Write to Slack? (y/n)"

This ensures daksh@ sees updated statuses as soon as a TestFlight goes out, without the user needing to remember to run `/chanakya sync-slack`.

## Feedback-ingest auto-trigger

In addition to the Slack-list sync, after a TestFlight release debrief is processed in Step 0B2, Chanakya **also** schedules a feedback-thread ingest for 24h later:

1. Locate the TestFlight thread posted by `postSlackTesting` (thread-ts is captured in the release debrief's `## Release Info` block, or — if missing — in `project_slack_list_sync.md` logs).
2. Append a row to the `## Reminders` table in `~/.dev-studio/<project>/feedback/active.md`:
   ```
   | <now+24h ISO-8601>  | ingest-reminder | #ios-testflight <thread-ts> --build <BUILD_NUMBER> | auto-scheduled after TF <BUILD_NUMBER> |
   ```
3. The adaptive-backoff sweep (Step 0E2) will fire it when `due_at` passes.

If the TestFlight thread-ts cannot be resolved, skip this step and surface a one-line warning — never block the release debrief on it.
