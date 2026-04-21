---
name: Chanakya Snapshots
description: Per-domain state snapshots that Chanakya modes read instead of hot-parsing source files. Producers, consumers, staleness windows, and invalidation map.
type: reference
---

# Chanakya Snapshots

Small per-domain JSON files that cache expensive reads for the router pattern. Each snapshot carries `generated_at` (ISO-8601 UTC) and `schema: 1`. Mode packs read them; fallback to full-load from source files is always available. Deleting any snapshot is safe — the next consumer regenerates it or falls back.

## Runtime location

`~/.dev-studio/<project>/.runtime/state/chanakya-snapshots/<domain>.json`

The skeleton JSONs committed under `chanakya/snapshots/` in this repo are fallback shapes only — never overwritten by the producer.

## Domains

| Domain | What it holds | Producer | Consumers | Source on fallback |
|---|---|---|---|---|
| `briefs` | Top 30 active tasks + full `by_status` histogram | `scripts/chanakya-snap.sh briefs` | status, brief | `plans/chanakya-master.md` |
| `debt` | Build / unit-test / UI-test counters + thresholds | `scripts/chanakya-snap.sh debt` | status, brief | `plans/chanakya-master.md` debt blocks |
| `feedback-inbox` | Up to 50 unprocessed feedback records with mtime + scope | `scripts/chanakya-snap.sh feedback-inbox` | status, ingest (dedupe hint) | `~/.dev-studio/generic-dev-studio/feedback-inbox/**` |
| `events-tail` | Last 25 events from today's event log | `scripts/chanakya-snap.sh events-tail` | status | `<project-memory>/events/<YYYY-MM-DD>.jsonl` |

## Staleness windows

| Consumer mode | Window | Why |
|---|---|---|
| `status` | 60s | Tolerates recent activity; short enough that newly-briefed / ingested items surface on the next call |
| `brief` | 5 min | Only consulted for display context; a stale briefs snapshot never drives a write |
| `ingest` | 5 min | Snapshot is a dedupe *hint* only — authoritative dedupe always reads `feedback/active.md` + `archive/**` |

Add a row when a new mode starts consuming a snapshot.

## Invalidation map

Modes fire a background `scripts/chanakya-snap.sh <domain> &` after any write that would otherwise leave a stale snapshot until its window expired:

| Mode write | Invalidates |
|---|---|
| `brief` — task status flips to `briefed` | `briefs` |
| `brief-all` — batch completes | `briefs` (once, post-loop) |
| `ingest-thread` / `ingest-dm` / `ingest-slack` — `active.md` updated | `feedback-inbox` |

Other domains auto-refresh via the consumer-side stale-read path: status mode fires `scripts/chanakya-snap.sh <domain> &` for any snapshot that was stale/missing when it read it. `debt` and `events-tail` drift slowly enough that this is sufficient.

## Pre-warm

`SessionStart` hook runs `scripts/chanakya-snap-prewarm.sh`, which detaches `chanakya-snap.sh all`. The next `/chanakya` invocation lands on fresh snapshots. Warm run: ~500-600ms for all four domains (measured on the gds project).

## Producer contract

Writes are atomic (`mktemp` + `jq empty` validation + `mv`). On failure, the previous snapshot stays in place and a `snapshot_failed` event fires. See `_shared/contracts/events.md` §Snapshot events for the full emission catalog.
