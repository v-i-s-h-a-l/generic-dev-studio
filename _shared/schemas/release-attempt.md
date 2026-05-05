---
name: Release Attempt Schema
description: YAML shape for resumable multi-system release operations under plans/release-attempts/<attempt-id>.yaml.
type: reference
---

# Release Attempt Schema (`release-attempt@1.0.0`)

A release attempt is the operation-level record Nabu uses when a release action
spans more than one external system. Release artifacts remain build/channel
records under `plans/releases/`; release attempts capture intent, side effects,
and transaction history for operations such as replacing a submitted build.

The artifact lives at
`~/.dev-studio/<project>/plans/release-attempts/<attempt-id>.yaml`.

## Shape

```yaml
schema_version:
  name: release-attempt
  version: 1.0.0
  min_reader: 1.0.0
  deprecated_at: null
id: 0191aaab-9000-7f01-8aaa-77fe8fa99bbb
operation: replace                         # submit | withdraw | resubmit | replace | release | expedite
channel: appstore                          # testflight | appstore
state: submitted                           # submitted | withdrawn | resubmitted | released | error
created_at: 2026-05-06T04:30:00Z
updated_at: 2026-05-06T04:35:00Z
intent:
  summary: "replace build 3047 with 3048"
  from_release_id: 0191aaaa-1111-7777-aaaa-111111111111
  to_release_id: 0191aaaa-2222-7777-aaaa-222222222222
  from_build: 3047
  to_build: 3048
  requested_by: operator
systems:
  app_store_connect:
    build_id: "1234567890"
    state: withdrawn
    updated_at: 2026-05-06T04:31:00Z
  git:
    original_tag: tf-1.12.0-3047
    withdrawn_tag: tf-1.12.0-3047-WITHDRAWN
    updated_at: 2026-05-06T04:32:00Z
  github_release:
    url: "https://github.com/org/repo/releases/tag/tf-1.12.0-3047-WITHDRAWN"
    draft: true
    updated_at: 2026-05-06T04:33:00Z
  messaging:
    channel_id: C0123456789
    parent_ts: "1745332800.001200"
    updated_at: 2026-05-06T04:34:00Z
  release_notes:
    artifact_id: 0191aaac-3333-7777-aaaa-333333333333
    content_sha256: "..."
    unchanged_from: null
    updated_at: 2026-05-06T04:35:00Z
side_effects:
  - key: app_store_connect.withdraw_build
    system: app_store_connect
    status: complete                       # pending | running | complete | skipped | failed
    started_at: 2026-05-06T04:30:10Z
    completed_at: 2026-05-06T04:31:00Z
    result_ref: systems.app_store_connect
  - key: release_notes.update_whats_new
    system: release_notes
    status: skipped
    reason: content_sha256 unchanged
transaction_log:
  - id: 0191aaab-aaaa-7777-aaaa-aaaaaaaaaaaa
    at: 2026-05-06T04:30:00Z
    actor: nabu
    type: intent                           # intent | side_effect_started | side_effect_completed | side_effect_failed | side_effect_skipped | transition | resume
    status: complete
    data:
      operation: replace
      from_build: 3047
      to_build: 3048
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | object | yes | Per `contracts/schema-version.md`. |
| `id` | UUIDv7 | yes | Attempt identifier; stable across retries. |
| `operation` | enum | yes | `submit`, `withdraw`, `resubmit`, `replace`, `release`, or `expedite`. |
| `channel` | enum | yes | `testflight` or `appstore`. |
| `state` | enum | yes | Per `state-machines/release-attempt-lifecycle.md`. |
| `created_at` / `updated_at` | RFC3339 UTC | yes | `updated_at` changes on every transaction append or state transition. |
| `intent` | object | yes | User/operator intent written before any side effect. For replacement, include the old and new release/build identifiers when known. |
| `systems` | object | yes | System-of-record sub-documents. Each adapter owns only its subsystem key. |
| `side_effects` | array | yes | Planned or observed adapter steps. Resume by finding the first side effect not `complete` or `skipped`. |
| `transaction_log` | array | yes | Append-only attempt history. Intent is always the first entry. |

## System-of-record ownership

`systems.app_store_connect` owns ASC build identifiers and ASC state.
`systems.git` owns local and remote tag anchors. `systems.github_release` owns
GitHub release URLs and draft/latest flags. `systems.messaging` owns channel and
thread identifiers. `systems.release_notes` owns versioned release-copy
artifact pointers and content hashes.

Adapters must update only their own sub-document and append a transaction entry.
Cross-system readers answer "where is this attempt?" from this artifact instead
of scanning release YAML, Slack threads, Git tags, and GitHub Releases
independently.

## Transaction Rules

1. Write `intent` and the first `transaction_log` entry before executing any
   side effect.
2. Mark each side effect `running` before the external call, then `complete`,
   `skipped`, or `failed` after it returns.
3. If the process stops, resume by reading `side_effects` and replaying only the
   first non-terminal item and everything after it.
4. Set `state: error` only when a failed side effect needs operator action. A
   retryable transport error can stay in the current state with a failed
   transaction entry.
5. Release-copy updates compare `systems.release_notes.content_sha256` before
   writing. Unchanged copy records `side_effect_skipped` rather than making a
   no-op external write.

## Related

- `state-machines/release-attempt-lifecycle.md` — operation-level state machine.
- `schemas/release.md` — build/channel release artifacts referenced from
  `intent.from_release_id`, `intent.to_release_id`, `replaces`, and
  `superseded_by`.
- `contracts/events.md` — release-attempt event catalog.
