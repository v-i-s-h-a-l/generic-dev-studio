---
name: Chanakya Ingest
description: Slack-source feedback ingestion — thread, DM, channel. Pulls messages, classifies feedback vs conversation, mints feedback records, downloads attachments, dedupes, emits feedback_ingested.
type: mode-pack
snapshots: [feedback-inbox.json]
budget_tokens: 3000
reads:
  - plans/index.yaml                               # post-migration feedback index for dedupe scan
  - plans/feedback/*.yaml                          # post-migration feedback artifacts (schema: _shared/schemas/feedback.md)
  - feedback/active.md                             # legacy dedupe surface until Commit H
  - feedback/archive/**/*.md                       # legacy dedupe surface until Commit H
  - .runtime/state/chanakya-snapshots/*.json       # snapshot cache
  - ~/.claude/secrets/slack-bot-token              # bot token for Slack API (read-only)
writes:
  - plans/feedback/<feedback-id>.yaml              # post-migration canonical (schema: _shared/schemas/feedback.md, feedback@1.0.0)
  - plans/feedback-attachments/<feedback-id>/*    # per-feedback asset bundle (post-migration)
  - plans/index.yaml                               # regenerated via scripts/rebuild-index.sh after artifact writes
  - feedback/active.md                             # legacy row append during Phase 2.6 transition
  - feedback/incoming/F<nnn>.md                    # legacy per-record markdown during Phase 2.6 transition
  - events/<date>.jsonl                            # via scripts/write-event.sh
---

# Ingest (Slack-source feedback minting)

Full spec: `project_feedback_lifecycle.md`. This mode pack owns three sub-commands that share a common pipeline (steps 2–8 are identical across all three); only the message-fetch step differs.

Snapshots: `snapshots/feedback-inbox.json` is consulted for dedupe hints (5-min freshness; if null/stale, fall back to reading `feedback/active.md` + walking `feedback/archive/**` directly — the authoritative dedupe source is always those files).

**Preconditions (all sub-commands).** Bot token at `~/.claude/secrets/slack-bot-token`. `feedback/active.md` below 100 rows (else refuse — block banner from Step 0D of review mode).

# Mode: Ingest-Thread (`/chanakya ingest-thread <channel> <thread-ts> [--build N] [--dry-run]`)

Pull a Slack thread, classify each message, mint F-ids.

## Steps

1. **Fetch thread.** `conversations.replies?channel=<channel>&ts=<thread-ts>&limit=200` with `Authorization: Bearer <token>`.
2. **Resolve reporters.** For each unique `user:` ID in the returned messages, call `users.info` once (cache in memory). Prefer `profile.display_name`, fall back to `name`.
3. **Download attachments.** For each message with `files[]`: `GET <url_private>` with the bot token, save to `~/.dev-studio/<project>/plans/feedback-attachments/<feedback-id>/<file_name>` (post-migration canonical path; legacy mirror at `chanakya-inbox/assets/thread-<thread-ts>/` retained during Phase 2.6 transition). Only HEIC/PNG/JPG/MP4/MOV.
4. **Classify each message** using the heuristic in `project_feedback_lifecycle.md` (screenshot/video/bullets/bug-language → feedback; short reply/emoji/ack → conversation).
5. **Dedupe.** Compute source key `slack-thread:<channel>/<thread-ts>/<message-ts>`. Post-migration: query `scripts/query-plans.sh --kind=feedback` and match against the `source_metadata.message_ts` + `channel` pair. Legacy fallback: scan `active.md` + `archive/**` for the source key. If any prior record carries this key, skip the message.
6. **Mint feedback record.** Mint a UUIDv7 for the new feedback artifact's `id`. Write to `~/.dev-studio/<project>/plans/feedback/<feedback-id>.yaml` per schema `_shared/schemas/feedback.md` (`feedback@1.0.0`). Populate `schema_version`, `state: ingested` (per `_shared/state-machines/feedback-lifecycle.md`), `source: slack-thread`, `reporter`, `source_metadata: {channel, thread_ts, message_ts, build, permalink}`, `ingested_at`, `subject`, `body`, `labels: []`, `linked_tasks: []`, `linked_crashes: []`, `root_cause_id: null`, `attachments: [{path, kind, size_bytes}]`, `resolved_by: null`, `resolved_at: null`.

   **Phase 2.6 transition note:** also append the legacy table row to `feedback/active.md` and write the legacy `feedback/incoming/F<nnn>.md` record (with the next monotonic human-readable F-id) for one cycle so in-flight consumers (`feedback-archive`, `feedback-history`, status sweep) still see the record. Cutover removes both legacy writes at Commit H.
7. **Emit event** per new feedback-id via `scripts/write-event.sh` (`_shared/contracts/events.md` + `_shared/contracts/event-emission.md`):
   ```json
   {"ts":"…","agent":"chanakya","event":"feedback_ingested","task":"<feedback-id>","data":{"source":"slack-thread","channel":"<channel>","thread_ts":"<thread-ts>","reporter":"<name>","build":<N>,"legacy_fid":"F<nnn>"}}
   ```
   Then regenerate `plans/index.yaml` via `scripts/rebuild-index.sh`.
8. **Report** a summary naming both the new feedback-ids and, for continuity during the Phase 2.6 transition, their legacy F-ids: "Ingested 3 new feedback records (F007/F008/F009, UUIDv7 ids <short>…) from #ios-testflight/1745... Skipped 11 conversation messages. Existing dedupes: 2."
9. **Invalidate feedback-inbox snapshot.** After `active.md` is written, fire `scripts/chanakya-snap.sh feedback-inbox &` in the background. Same reasoning as brief mode: a user who ingests then immediately runs `/chanakya` expects to see the new F-ids without waiting 60 seconds for the snapshot window to expire. Skip this on `--dry-run` (no filesystem writes, nothing to invalidate).

## `--dry-run`

Run Steps 1–5 only. Print what *would* be written to `active.md` as a diff (added rows) and list F-id ranges. Do not touch the filesystem beyond reading.

## Failure modes

- Bot token missing → surface install hint, exit.
- Rate-limit (429) → back off per `Retry-After`, resume. Never lose partial progress: F-records that have been minted stay minted.
- Attachment download fails → record `screenshot_path: (download-failed — <url>, <error>)` so the record is still usable.

---

# Mode: Ingest-DM (`/chanakya ingest-dm <user> [--since ts] [--dry-run]`)

Same pipeline against a DM. Resolve the IM channel with `conversations.open?users=<user>` (or `users.info` → open), then `conversations.history?channel=<im_channel>&oldest=<since>`. Source key: `slack-dm:<user>/<message-ts>`.

`--since` defaults to the last F-id from this user's DM in the archive (or 24h ago if none).

Steps 2–8 identical to Ingest-Thread (classification, dedupe, F-mint, event, report).

---

# Mode: Ingest-Channel (`/chanakya ingest-slack [--channel id] [--since ts] [--dry-run]`)

Scan **top-level** messages in a channel (exclude thread replies — those belong to Ingest-Thread). Use `conversations.history?channel=<id>&oldest=<since>` and filter out messages with a `thread_ts` that differs from their own `ts` (i.e. replies).

Source key: `slack-slack:<channel>/<message-ts>`.

`--channel` defaults to `#product-bugs` (or whatever channel is pinned in `project_slack_list_sync.md`). `--since` defaults to 24h ago.

Steps 2–8 identical. When a thread reply is detected, the reporter's top-level message still gets classified — but a note is added to `original_message`: "(has N replies — consider `ingest-thread`)".
