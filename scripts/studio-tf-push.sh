#!/usr/bin/env bash
# studio-tf-push.sh — studio-owned TestFlight / App Store Connect push driver.
#
# Skeleton implementation per `_shared/contracts/release-tf-push.md` (Stage B
# of #217). This is the entry point Stage E will swap `/pushTFBuild` over to.
#
# Today the script:
#   1. Routes to the laptop via `node-pick --requires-secret-scope asc,slack`.
#   2. Walks the 14 logical steps from the contract (collapsed into 6 phases).
#   3. Emits the seven events the contract registers — `release_started`,
#      `archive_completed`, `upload_completed`, `dsym_uploaded`, `slack_drafted`,
#      `slack_sent`, plus `release_failed` on the failure path.
#   4. Stubs every external-effect step (archive, upload, dSYM upload, Slack
#      send) behind the `STUDIO_TF_PUSH_LIVE=1` env-var gate. Default off — the
#      script refuses loud per R14 if asked to do real work without the gate.
#
# Real archive / upload / Slack bodies port from the user's `~/.claude/commands/
# pushTFBuild.md` once Stage D's Slack primitives exist and a release window is
# open (Stage E). This file holds the shape; Stage E fills it in.
#
# Usage:
#   scripts/studio-tf-push.sh [--dry-run]
#
# Flags:
#   --dry-run   skip every external effect (no archive, no upload, no Slack
#               post). Emits all six events with `mode: "dry-run"` in the data
#               payload so dashboards can filter rehearsal runs out. Exit 0
#               on a clean walk; exit non-zero only if the routing or event
#               emission itself broke.
#
# Env:
#   STUDIO_TF_PUSH_LIVE=1   required to run any real external effect. Without
#                           it (and without --dry-run), the script halts at
#                           the prereq gate and emits `release_failed` with
#                           `stage: "prereq"` — Stage E flips this default
#                           once the live wrappers land.
#   STUDIO_TF_PUSH_FIXTURE_NODE   override the resolved node id (smoke tests
#                                 read this to assert routing without touching
#                                 the real registry).

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

# ---------- args ----------

DRY_RUN_FLAG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN_FLAG=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --) shift; break ;;
    *) printf 'studio-tf-push: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
done

LIVE="${STUDIO_TF_PUSH_LIVE:-0}"

# ---------- release tag (idempotency key, per contract §Idempotency) ----------

RELEASE_TAG="release-pending-$(date -u +%Y%m%d-%H%M%S)"

# ---------- helpers ----------

# Build a JSON object from k=v pairs. Values are JSON-escaped.
_json_obj() {
  local out='{}'
  for kv in "$@"; do
    case "$kv" in
      *=*)
        local k="${kv%%=*}" v="${kv#*=}"
        out=$(printf '%s' "$out" | jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}')
        ;;
    esac
  done
  printf '%s' "$out"
}

# emit_release <event> <data-json>
emit_release() {
  local event="$1" data="${2:-{\}}"
  if [ "$DRY_RUN_FLAG" = "1" ]; then
    data=$(printf '%s' "$data" | jq -c '. + {"mode":"dry-run"}')
  fi
  emit_event_keyed studio release "$event" "$RELEASE_TAG" "$data" >/dev/null
}

halt_failed() {
  local stage="$1" reason="$2"
  local data
  data=$(_json_obj "stage=$stage" "reason=$reason")
  emit_release release_failed "$data"
  printf 'studio-tf-push: halted at %s — %s\n' "$stage" "$reason" >&2
  exit 1
}

# ---------- Phase 0 — Resolve dispatch node (Stage A integration) ----------

if [ -n "${STUDIO_TF_PUSH_FIXTURE_NODE:-}" ]; then
  NODE="$STUDIO_TF_PUSH_FIXTURE_NODE"
else
  NODE=$("$SCRIPT_DIR/node-pick.sh" --requires-secret-scope asc,slack release 2>/dev/null || echo local)
fi

if [ "$NODE" = "local" ]; then
  # `local` here means no node advertised both scopes — fail loud rather than
  # run secret-bearing code on an unauthorized host. Stage A's `node_fallback`
  # event already carries the diagnostic; this halt is the policy enforcement.
  halt_failed prereq "no node advertises asc,slack scopes — refusing to run secret-bearing work locally"
fi

printf 'studio-tf-push: routed to %s (release-tag=%s, dry-run=%s, live=%s)\n' \
  "$NODE" "$RELEASE_TAG" "$DRY_RUN_FLAG" "$LIVE"

# ---------- Phase 1 — Prereqs + ASC state (contract Steps 1–2) ----------

# Live work without the gate is refused per R14 — emit a release_failed and
# exit. Dry-run does not need the gate; the whole point is a credential-free
# rehearsal of the event sequence.
if [ "$DRY_RUN_FLAG" != "1" ] && [ "$LIVE" != "1" ]; then
  halt_failed prereq "STUDIO_TF_PUSH_LIVE=1 required for non-dry-run; refusing real archive/upload (R14)"
fi

# Stub values for the dry-run skeleton. Stage E replaces these with live ASC
# reads + pbxproj parsing per contract §Step 1.
BUILD_FROM=0
LIVE_VERSION="0.0.0"
CURRENT_VERSION="0.0.0"
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
NEW_BUILD_NUMBER=$((BUILD_FROM + 1))
VERSION="$CURRENT_VERSION"

emit_release release_started "$(_json_obj \
  "build_from=$BUILD_FROM" \
  "live_version=$LIVE_VERSION" \
  "current_version=$CURRENT_VERSION" \
  "branch=$BRANCH")"

# ---------- Phase 2 — Archive (contract Steps 3–4) ----------

ARCHIVE_PATH="/tmp/stub-$NEW_BUILD_NUMBER.xcarchive"
SCHEME="stub"

if [ "$DRY_RUN_FLAG" = "1" ]; then
  printf 'studio-tf-push: [dry-run] would archive scheme=%s build=%s → %s\n' \
    "$SCHEME" "$NEW_BUILD_NUMBER" "$ARCHIVE_PATH"
else
  # Stage E owns the live xcodebuild archive call. Skeleton refuses to invoke
  # it — see header comment.
  halt_failed archive "live archive not implemented — Stage E ports from pushTFBuild.md"
fi

emit_release archive_completed "$(_json_obj \
  "build=$NEW_BUILD_NUMBER" \
  "version=$VERSION" \
  "scheme=$SCHEME" \
  "archive_path=$ARCHIVE_PATH" \
  "duration_s=0")"

# ---------- Phase 3 — Export + upload (contract Step 5) ----------

if [ "$DRY_RUN_FLAG" = "1" ]; then
  printf 'studio-tf-push: [dry-run] would export + upload build %s to ASC\n' "$NEW_BUILD_NUMBER"
else
  halt_failed upload "live upload not implemented — Stage E"
fi

emit_release upload_completed "$(_json_obj \
  "build=$NEW_BUILD_NUMBER" \
  "version=$VERSION" \
  "duration_s=0")"

# ---------- Phase 4 — dSYM upload (contract Step 6) ----------

if [ "$DRY_RUN_FLAG" = "1" ]; then
  printf 'studio-tf-push: [dry-run] would upload dSYMs to Crashlytics\n'
fi

emit_release dsym_uploaded "$(_json_obj \
  "build=$NEW_BUILD_NUMBER" \
  "count_succeeded=0" \
  "count_failed=0" \
  "count_skipped=0" \
  "reason=dry_run")"

# ---------- Phase 5 — Compose + draft Slack (contract Steps 7–8) ----------

if [ "$DRY_RUN_FLAG" = "1" ]; then
  printf 'studio-tf-push: [dry-run] would compose Slack draft + show approval gate\n'
else
  halt_failed draft "live Slack composition not implemented — Stage D + E"
fi

emit_release slack_drafted "$(_json_obj \
  "build=$NEW_BUILD_NUMBER" \
  "channel=#testing" \
  "bullet_count=0" \
  "cc_count=0")"

# ---------- Phase 6 — Send (contract Step 9) ----------

if [ "$DRY_RUN_FLAG" = "1" ]; then
  printf 'studio-tf-push: [dry-run] would post to #testing on user approval\n'
  PARENT_TS="0000000000.000000"
else
  halt_failed slack_send "live Slack post not implemented — Stage D + E"
fi

emit_release slack_sent "$(_json_obj \
  "build=$NEW_BUILD_NUMBER" \
  "channel=#testing" \
  "parent_ts=$PARENT_TS" \
  "message_chars=0")"

printf 'studio-tf-push: complete (release-tag=%s)\n' "$RELEASE_TAG"
exit 0
