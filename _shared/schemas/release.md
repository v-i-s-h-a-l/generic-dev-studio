---
name: Release Schema
description: YAML shape for TestFlight / App Store release artifacts under plans/releases/<release-id>.yaml. One artifact per build submitted to a release channel. Replaces the Release Log table row in the legacy master plan.
type: reference
---

# Release Schema (`release@1.1.0`)

Per-release artifact written to `~/.dev-studio/<project>/plans/releases/<release-id>.yaml`. One file per build submitted to a release channel (TestFlight or App Store). Authored by `/achilles push-tf` or `/achilles app-store`; updated by `scripts/appstore-watch.sh` as the release transitions states.

Version 1.1.0 is non-breaking — adds the optional `replaced_by` and `cancelled_reason` fields to support the cancel-and-replace flow Nabu (#214) needs. `min_reader: 1.0.0` keeps the entire active fleet compatible.

Release state transitions governed by `state-machines/release-lifecycle.md` (landed alongside this schema in Phase 2.6 Commit B).

## Shape

```yaml
schema_version:
  name: release
  version: 1.1.0
  min_reader: 1.0.0
  deprecated_at: null
id: 0190f52a-9000-7f01-8aaa-77fe8fa99bbb        # UUIDv7
channel: testflight                              # testflight | appstore
state: submitted                                 # drafted | submitted | in-review | pending-developer-release | released | rejected | cancelled | archived
build_number: 3047
version: "1.12.0"
tag: "TF-3047"                                   # GitHub release tag
commit_sha: "a1b2c3d4e5f60718293a4b5c6d7e8f90"
submitted_at: 2026-04-22T14:00:00Z
last_state_checked_at: 2026-04-22T14:32:11Z
released_at: null
replaced_by: null                                # 1.1.0; release-id of the build that replaced this one (cancel→replace flow); null otherwise
cancelled_reason: null                           # 1.1.0; free-text reason populated when state == cancelled; null otherwise
tasks:
  - 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11        # task-ids included in this release
  - 0190f52a-6f15-7b4c-9b2e-1e5faa80f622
reviews:
  - 0190f52a-7b22-7e04-8cff-66ef7ec99c99        # pre-release review-ids (if any)
asc_metadata:
  asc_build_id: "1234567890"                     # App Store Connect build identifier
  app_store_state: "WAITING_FOR_REVIEW"          # ASC appStoreState verbatim
  last_poll_at: 2026-04-22T14:32:11Z
  next_check_at: 2026-04-22T15:02:11Z
  consecutive_failures: 0
  stuck: false
slack:
  posted_to: "#releases"
  message_ts: "1745332800.001200"
  reply_ts: null                                 # filled when watcher finalizes
notes: null
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | object | yes | Per `contracts/schema-version.md`. |
| `id` | string (UUIDv7) | yes | |
| `channel` | enum | yes | `testflight` \| `appstore`. |
| `state` | enum | yes | Per `state-machines/release-lifecycle.md`. |
| `build_number` | integer ≥ 1 | yes | Xcode build number at submission. |
| `version` | string | yes | Marketing version (e.g. "1.12.0"). |
| `tag` | string | yes | GitHub release tag (e.g. "TF-3047", "AS-3047"). |
| `commit_sha` | string | yes | Full-length SHA of the commit that was archived. |
| `submitted_at` | RFC3339 UTC | yes | When the build was submitted to ASC. |
| `last_state_checked_at` | RFC3339 UTC \| null | yes | Null until first watcher poll. |
| `released_at` | RFC3339 UTC \| null | yes | Set when state transitions to `released`. |
| `tasks` | array of UUIDv7 | yes | Task-ids shipped in this release. Bidirectional with `task.links.release`. |
| `reviews` | array of UUIDv7 | yes | Pre-release review artifacts (e.g. release-gate reviews). |
| `asc_metadata` | object \| null | yes | ASC poll state. Null for channels without ASC (none today). |
| `slack` | object \| null | yes | Slack post metadata for release announcements. Null when no post made. |
| `notes` | string \| null | yes | Optional commentary. |
| `replaced_by` | UUIDv7 \| null | no (1.1.0) | When set, names the release-id of the build that replaced this one — the cancel-and-replace pattern (cancel build N, ship build M instead). Setting `replaced_by` requires `state == cancelled`. Default when absent: `null` (release was not replaced). Consumed by Nabu (#214) for release-replacement-ready suggestions. |
| `cancelled_reason` | string \| null | no (1.1.0) | Free-text reason ≤ 280 chars; populated when `state == cancelled`. Default when absent: `null`. Surfaces in `/chanakya status` release banner. |

## Channels

### `testflight`

External / internal testing. State machine typically: `drafted → submitted → released` (TestFlight processes builds without review). `appstore_state` field from ASC is still meaningful (build-processing states — `PROCESSING`, `INVALID_BINARY`, etc.).

### `appstore`

Production submission. Full state machine including `in-review`, `pending-developer-release`, `rejected`. `scripts/appstore-watch.sh` polls and drives state transitions.

## Lifecycle

See `state-machines/release-lifecycle.md`. Summary:

```
drafted → submitted → in-review → pending-developer-release → released
                                                                → archived
                                → rejected
                                → cancelled
submitted → released   (TestFlight processes without formal review)
any     → archived     (compact sweep)
```

Transitions emit `release_state_changed` (new event catalog entry landing alongside the state machine).

## ASC metadata

When `channel: appstore`, the watcher (`scripts/appstore-watch.sh`) updates:

```yaml
asc_metadata:
  asc_build_id: "1234567890"                     # stable from first poll
  app_store_state: "WAITING_FOR_REVIEW"          # ASC verbatim — case-sensitive
  last_poll_at: 2026-04-22T14:32:11Z
  next_check_at: 2026-04-22T15:02:11Z             # self-throttling; watcher skips until this time
  consecutive_failures: 0                         # JWT errors, ASC API errors, Slack post errors
  stuck: false                                    # true when ≥3 consecutive failures
```

Surfaced via `/chanakya status` release banner when `stuck: true`.

## Links

- `tasks[]` back-refs task-ids. `task.links.release = release.id` for each task in the array. Bidirectional consistency checked by the plans-index validator.
- `reviews[]` back-refs review-ids whose `subject.kind = release, subject.id = release.id`.

## Migration note (2.6)

Legacy release-log rows in the master plan (`## Release Log` table with columns Build / Version / Type / Date / Tag / HEAD / Tasks Included) migrate to individual `plans/releases/<release-id>.yaml` files. Transform:

1. Parses each row into a release artifact.
2. Promotes `Tasks Included` (task-id list) into `tasks[]`.
3. State is inferred from presence of `released_at` / ASC marker files.
4. Missing `asc_metadata` is populated from any remaining ASC JSON marker files (`pending-appstore-review.json`); otherwise null.

Active watcher state files (`pending-appstore-review.json`) migrate into the per-release `asc_metadata` block; the standalone JSON files are retired.

## History table

| Version | Landed | Changes |
|---|---|---|
| 1.1.0 | 2026-04-27 | Non-breaking: add optional `replaced_by` (release-id pointer) and `cancelled_reason` (free text) fields for the cancel-and-replace flow that Nabu (#214) consumes (#247 Stage C deliverable 2). |
| 1.0.0 | 2026-04-22 | Initial Phase 2.6 landing alongside `state-machines/release-lifecycle.md`. |

## Related

- `state-machines/release-lifecycle.md` — transitions (ships in Commit B).
- `schemas/task.md` — tasks referenced by `tasks[]`.
- `schemas/review.md` — release-gate reviews.
- `contracts/events.md` — `release_state_changed`, `appstore_*` catalog entries.
- `scripts/appstore-watch.sh` — ASC poller.
