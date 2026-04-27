---
name: Chanakya Digest
description: State-change rollup over a time window (day/week/month). Groups task_state_changed events by destination state, with per-train breakdowns. Default window is day.
type: mode-pack
schema_version: 1
budget_tokens: 1000
snapshots: []
reads:
  - events/<date>.jsonl                            # task_state_changed events; one file per calendar day in the window
  - plans/tasks/*.yaml                             # train + title for each task ID seen in events
writes: []
---

# Mode: Digest (`/chanakya digest [day|week|month]`)

Roll up `task_state_changed` events over a time window, grouped by destination state with per-train breakdowns. Default window is `day` (last 24 hours).

## Step 1 — Resolve window

Derive `start_ts` and `end_ts` (ISO-8601 UTC) from the argument:

| Arg | Window |
|---|---|
| `day` (default) | `[now − 24h, now]` |
| `week` | `[now − 7d, now]` |
| `month` | `[now − 30d, now]` |

Collect the set of calendar-date filenames that overlap the window:

```bash
start_date=$(date -u -v-1d +%Y-%m-%d)   # day; adjust for week/month
```

For each date in the range, READ `~/.dev-studio/<project>/events/<YYYY-MM-DD>.jsonl` if it exists. Skip missing files silently.

## Step 2 — Filter events

From each event log file, extract lines where `event == "task_state_changed"` AND `ts` falls within `[start_ts, end_ts]`. Deduplicate by `idempotency_key` — keep the first occurrence only.

Parse each matching line to extract: `ts`, `task` (UUID), `data.from`, `data.to`.

## Step 3 — Join task metadata

For each unique `task` UUID collected in Step 2, READ `plans/tasks/<uuid>.yaml`. Extract `train` (null if absent) and `title`. Cache in memory; do not re-read the same file twice.

For tasks whose YAML is missing (e.g. archived or deleted), treat `train` as `null` and `title` as `<unknown>`.

## Step 4 — Group and count

Build a map: `state_counts[to_state][train_or_null] = count`.

Accumulate one count per deduplicated event. `train_or_null` is the string value from the task YAML, or the sentinel `ad-hoc` when `train == null`.

## Step 5 — Render

Print the header line, then one row per destination state that has at least one transition. Order rows by lifecycle sequence: `proposed → briefed → dispatched → in-progress → merged → verified → archived → cancelled → reopened`.

Header format:

```
Digest — last <window> (<start_date> → <end_date>)
```

For each state with transitions:

```
  <state>:  <total> task(s)
```

When more than one train is present for a state, expand per-train:

```
  <state>:  <total> task(s)  (<train1>: N, <train2>: M, ad-hoc: K)
```

Omit the per-train breakdown when all tasks for that state are `ad-hoc`.

Full example output:

```
Digest — last 24h (2026-04-26 → 2026-04-27)
  proposed:    3 task(s)
  briefed:     5 task(s)  (lean-task-arc: 3, ad-hoc: 2)
  dispatched:  4 task(s)
  merged:      6 task(s)  (lean-task-arc: 4, comms-revamp: 1, ad-hoc: 1)
  verified:    2 task(s)
  reopened:    1 task(s)
```

When no transitions exist in the window, print exactly: `Digest — no state transitions in the last <window>.`

## Output discipline

READ-only mode. No Step 0 inbox sweep (no mutation needed). Output is pipeable — no spinner, no trailing banners.

## Failure modes

| Failure | Classification | Action |
|---|---|---|
| Event log file missing for a date in the window | transient | SKIP that date; continue with available files |
| Task YAML missing for a UUID in events | permanent | RECORD `train` as null, `title` as `<unknown>`; continue |
| Invalid JSON line in event log | transient | SKIP that line; continue |
