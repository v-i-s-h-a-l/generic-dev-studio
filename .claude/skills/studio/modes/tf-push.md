---
name: Studio TF Push
description: Studio-owned TestFlight / App Store Connect push driver. Thin wrapper over `scripts/studio-tf-push.sh`. Refuses live archive/upload without `STUDIO_TF_PUSH_LIVE=1`. Stage C of #217.
type: mode-pack
schema_version: 1
budget_tokens: 600
snapshots: []
reads:
  - _shared/contracts/release-tf-push.md
  - scripts/studio-tf-push.sh
writes:
  - studio event log (release_started, archive_completed, upload_completed, dsym_uploaded, slack_drafted, slack_sent)
---

# Mode: TF Push (Studio)

Fired when the user says `/studio tf-push`, "push a TestFlight build via studio", or invokes the Stage E live wrappers (once shipped). Skeleton today — real archive / upload / Slack bodies port from `~/.claude/commands/pushTFBuild.md` in Stage E.

The driver lives at `scripts/studio-tf-push.sh`. This mode pack is the dispatch surface; the script is the procedure. The contract at `_shared/contracts/release-tf-push.md` is the source of truth for both.

## Step 1 — Decide live vs. rehearsal

| Caller intent | Invocation |
|---|---|
| Rehearsal / smoke / CI | `scripts/studio-tf-push.sh --dry-run` |
| Real release (Stage E only) | `STUDIO_TF_PUSH_LIVE=1 scripts/studio-tf-push.sh` |
| Real release while drafting Slack in-session | `STUDIO_TF_PUSH_LIVE=1 scripts/studio-tf-push.sh push --background` |
| Explicit marketing version | `scripts/studio-tf-push.sh --version <X.Y.Z>` or `STUDIO_TF_FORCE_VERSION=<X.Y.Z>` |

The script refuses non-dry-run work without `STUDIO_TF_PUSH_LIVE=1` (R14). It prints the resolved version decision before archive, refuses known rejected App Store versions, and treats an already-applied pbxproj bump as success instead of a misleading commit failure.

With `--background`, the script returns a JSON handle immediately and writes `prepared-context.json`, `status.json`, `context.json`, and `push.log` under `~/.dev-studio/<project>/state/release-runs/<release-tag>/`. Use the prepared context to draft Slack while archive/upload continue; require final status `succeeded` before emitting `slack_sent`.

## Step 2 — Routing

The script calls `node-pick.sh --requires-secret-scope asc,slack release` before any side effect. Today only the laptop entry advertises both scopes — TF/AS work routes there, period. If `node-pick` returns `local`, the script halts with `release_failed.stage=prereq` rather than running secret-bearing code on an unauthorized host.

## Step 3 — Events

The contract's seven events fire in order: `release_started` → `archive_completed` → `upload_completed` → `dsym_uploaded` → `slack_drafted` → `slack_sent`, with `release_failed` as the failure terminator. All carry the same `release-<build>-<utc>` task field for span join. Dry-run sets `data.mode = "dry-run"` so dashboards can filter rehearsal traffic.

## Never

- Run a real archive/upload without `STUDIO_TF_PUSH_LIVE=1`.
- Bypass `node-pick` and dispatch elsewhere.
- Drift from the event taxonomy in `_shared/contracts/release-tf-push.md` — that contract is authoritative for Stage E and a future Nabu mode pack.

## Fixture

`tests/mode-packs/studio/tf-push.yaml` (TODO Stage E) — subagent must invoke the script with `--dry-run`, observe all six success events, refuse to advance without the live env-var, and never touch ASC or Slack.
