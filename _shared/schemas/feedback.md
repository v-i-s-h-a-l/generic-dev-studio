---
name: Feedback Schema
description: YAML shape for feedback records under plans/feedback/<feedback-id>.yaml. Minted from Slack threads, DMs, user-testing rounds, or crash reports. One feedback-id per distinct reporter-signal.
type: reference
---

# Feedback Schema (`feedback@1.0.0`)

Per-feedback artifact written to `~/.dev-studio/<project>/plans/feedback/<feedback-id>.yaml`. Minted by Chanakya's ingest modes (`/chanakya ingest-slack`, `/chanakya ingest-thread`, `/chanakya ingest-dm`) or by the round-feedback ingest path. One file per distinct reporter-signal; de-duplication relies on the idempotency key of the ingest event, not on content hashing.

The feedback-lifecycle state machine ships in Phase 2.7; 2.6 lands the schema and the minimal state enum so ingesters have a stable write target.

## Shape

```yaml
schema_version:
  name: feedback
  version: 1.0.0
  min_reader: 1.0.0
  deprecated_at: null
id: 0190f52a-a000-7001-8bbb-88ff9fa11ccc        # UUIDv7
state: ingested                                  # ingested | triaged | linked | resolved | dismissed | archived
source: slack-thread                             # slack-thread | slack-dm | slack-channel | round | crash | user-direct
reporter: "U0ABCDEF12"                           # Slack user-id | email | name | "anonymous"
source_metadata:
  channel: "C09KZ1A2BC3"                         # Slack channel-id (when applicable)
  thread_ts: "1745332800.001200"
  message_ts: "1745332800.001200"
  build: "TF-3047"                               # build tag, when derivable
  permalink: "https://slack.com/archives/C09KZ1A2BC3/p1745332800001200"
ingested_at: 2026-04-22T15:10:00Z
subject: "Filter preset row not scrolling on iPhone SE"
body: |
  User reported the filter preset row is unresponsive on iPhone SE
  (3rd gen) running iOS 16.4. Works on iPhone 15. Attached screen recording.
labels:
  - ui-bug
  - device-specific
linked_tasks:
  - 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11        # task-id linked by Chanakya's review-feedback mode
linked_crashes: []
root_cause_id: null                              # feedback-id of the promoted root-cause, if any
attachments:
  - path: "~/.dev-studio/<project>/plans/feedback-attachments/<feedback-id>/screen.mov"
    kind: video
    size_bytes: 2048192
resolved_by: null                                # task-id | release-id | null
resolved_at: null
notes: null
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | object | yes | Per `contracts/schema-version.md`. |
| `id` | string (UUIDv7) | yes | |
| `state` | enum | yes | `ingested` \| `triaged` \| `linked` \| `resolved` \| `dismissed` \| `archived`. Full lifecycle in 2.7. |
| `source` | enum | yes | `slack-thread` \| `slack-dm` \| `slack-channel` \| `round` \| `crash` \| `user-direct`. |
| `reporter` | string | yes | Source-specific identifier (Slack user-id, email, name, or `"anonymous"`). |
| `source_metadata` | object | yes | Source-specific fields. Slack: `{channel, thread_ts, message_ts, build, permalink}`. Round: `{round_id, case_id}`. Crash: `{crash_id}`. |
| `ingested_at` | RFC3339 UTC | yes | When the feedback was minted. |
| `subject` | string | yes | Short label, ≤ 200 chars. |
| `body` | string (multiline markdown) | yes | Full reporter narrative + any bot-added context. |
| `labels` | array of strings | yes | Free-form tags — triaged by Chanakya compact mode. Common: `ui-bug`, `crash`, `perf`, `device-specific`, `root_cause`. Empty array allowed. |
| `linked_tasks` | array of UUIDv7 | yes | Tasks that address this feedback. Populated by `/chanakya review-feedback` or manual link. |
| `linked_crashes` | array of UUIDv7 | yes | Crash-ids (per `schemas/crash.md`) this feedback correlates to. |
| `root_cause_id` | UUIDv7 \| null | yes | When Chanakya promotes a recurring-feedback cluster to a root-cause, instances back-ref the promoted record. Null otherwise. |
| `attachments` | array | yes | Per-attachment `{path, kind, size_bytes}`. `kind ∈ {image, video, log, other}`. Empty array when none. |
| `resolved_by` | UUIDv7 \| null | yes | Task-id or release-id that resolved the feedback. Null while unresolved. |
| `resolved_at` | RFC3339 UTC \| null | yes | Set on `state: resolved`. |
| `notes` | string \| null | yes | Triage commentary. |

## States

| State | Meaning |
|---|---|
| `ingested` | Just minted. No triage. |
| `triaged` | Labels + notes added by Chanakya compact sweep. |
| `linked` | Linked to a task (`linked_tasks` non-empty). |
| `resolved` | Task/release that addresses it is marked verified or released. |
| `dismissed` | User-rejected or not-actionable. Terminal. |
| `archived` | Post-compact cold storage. Terminal. |

Full lifecycle transitions ship with `state-machines/feedback-lifecycle.md` in Phase 2.7.

## Links

- `linked_tasks` — bidirectional with `task.links.feedback`.
- `linked_crashes` — bidirectional with `crash.linked_feedback` (see `schemas/crash.md`).
- `root_cause_id` — points at another `feedback.yaml` (the promoted root-cause). Reverse reference lives in the root-cause's `labels: [root_cause]` + implicit inbound scan.

## Migration note (2.6)

Legacy feedback lived under `feedback-inbox/<source-project>/` as markdown records (`reports/<report-id>.md`, `reporters/<reporter>.md`, `root-causes/<rc-id>.md`). Migration:

1. **`reports/*.md`** → `plans/feedback/<feedback-id>.yaml`. Transform extracts the Slack permalink / thread metadata from the header.
2. **`root-causes/*.md`** → `plans/feedback/<feedback-id>.yaml` with `labels: [root_cause]`. Instances that referenced the old RC get `root_cause_id` set to the new UUIDv7.
3. **`reporters/*.md`** — index-only files that aggregated per-reporter history. **Not migrated** — reproduced by `plans/index.yaml` queries post-cutover.
4. Empty placeholder dirs (`archive/`, `reporters/`, `root-causes/` with only `.gitkeep`) are pruned at cutover per Q19. Recreated lazily on first real write.

## History table

| Version | Landed | Changes |
|---|---|---|
| 1.0.0 | 2026-04-22 | Initial Phase 2.6 landing. State lifecycle finalized in 2.7. |

## Related

- `schemas/task.md` — tasks linked via `linked_tasks`.
- `schemas/crash.md` — crashes linked via `linked_crashes`.
- `schemas/round.md` — rounds that source `source: round` feedback.
- `contracts/events.md` — `feedback_ingested`, `feedback_archived`, `root_cause_promoted`.
