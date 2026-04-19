#!/usr/bin/env bash
# appstore-watch.sh — single-tick App Store Connect observer.
#
# Invoked by Chanakya Step 0B3 on every sweep. Self-gated on the marker's
# next_check_at, so it's safe (and cheap) to call every sweep — most calls
# exit immediately. The marker file drives everything:
#
#   ~/.dev-studio/<project>/.runtime/state/pending-appstore-review.json
#
# Written by /fullSendToAppStore after submission. Absent marker → no-op.
# Wrong project → no-op.
#
# On terminal state (PENDING_DEVELOPER_RELEASE / READY_FOR_SALE):
#   1. gh release edit <tag> --draft=false
#   2. Threaded Slack reply on the original #releases message
#   3. Delete marker
#   4. Emit appstore_released
# Steps 1 and 2 are tracked in marker.finalize_progress for idempotency —
# a partial failure re-attempts only the unfinished step on the next sweep.
#
# On non-terminal: update last_state + next_check_at (30–60 min jitter),
# emit appstore_state_checked.
#
# On any failure: bump marker.failures; at >=3 emit appstore_watch_stuck
# and leave marker for operator resolution (retries continue).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT=$(resolve_project 2>/dev/null) || exit 0
ROOT=$(resolve_project_root_for "$PROJECT")
MARKER="$ROOT/.runtime/state/pending-appstore-review.json"
[ -f "$MARKER" ] || exit 0

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

py() { python3 -c "$1" "$@"; }

read_field() {
  python3 - "$MARKER" "$1" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
except Exception:
    v = ""
print(v if v is not None else "")
PY
}

MARKER_PROJECT=$(read_field project)
[ "$MARKER_PROJECT" = "$PROJECT" ] || exit 0

NEXT_CHECK=$(read_field next_check_at)
NOW_EPOCH=$(date -u +%s)
NEXT_EPOCH=$(ts_to_epoch "$NEXT_CHECK" 2>/dev/null || echo 0)
[ -z "$NEXT_EPOCH" ] && NEXT_EPOCH=0
if [ "$NEXT_EPOCH" -gt "$NOW_EPOCH" ]; then
  exit 0
fi

TAG=$(read_field tag)
VERSION=$(read_field version)
APP_ID=$(read_field asc_app_id)
REPO=$(read_field repo)
CHANNEL=$(read_field slack_channel)
PARENT_TS=$(read_field slack_parent_ts)
URL=$(read_field github_release_url)
KEY_PATH=$(read_field asc_key_path)
ISSUER_ID=$(read_field asc_issuer_id)
KEY_ID=$(read_field asc_key_id)

for f in TAG VERSION APP_ID KEY_PATH ISSUER_ID KEY_ID; do
  if [ -z "${!f}" ]; then
    echo "[appstore-watch] marker missing $f — aborting" >&2
    exit 1
  fi
done

if [ ! -f "$KEY_PATH" ]; then
  echo "[appstore-watch] ASC key not found at $KEY_PATH — skipping" >&2
  exit 0
fi

# Bump failure counter, update cadence, optionally mark stuck. Reused across
# all error paths. Args: <reason> [<partial-state>]
mark_failure() {
  local reason="$1" partial="${2:-}"
  python3 - "$MARKER" "$reason" "$partial" "$NOW_ISO" <<'PY'
import json, sys, datetime
p = sys.argv[1]
m = json.load(open(p))
m['failures'] = m.get('failures', 0) + 1
m['last_error'] = sys.argv[2]
m['last_check_at'] = sys.argv[4]
if sys.argv[3]:
    m['last_state'] = sys.argv[3]
if m['failures'] >= 3:
    m['stuck'] = True
# Retry next sweep, but not immediately — 30 min minimum.
nxt = datetime.datetime.utcnow() + datetime.timedelta(minutes=30)
m['next_check_at'] = nxt.strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump(m, open(p, 'w'), indent=2)
print(m.get('failures', 0))
PY
}

# Generate ASC JWT (pattern from _shared/appstore-connect-jwt.md).
TOKEN=$(python3 - "$KEY_PATH" "$ISSUER_ID" "$KEY_ID" <<'PY'
import jwt, time, sys
key_path, issuer, kid = sys.argv[1], sys.argv[2], sys.argv[3]
key = open(key_path).read()
payload = {'iss': issuer, 'iat': int(time.time()), 'exp': int(time.time()) + 1200, 'aud': 'appstoreconnect-v1'}
print(jwt.encode(payload, key, algorithm='ES256', headers={'kid': kid}))
PY
) || {
  fails=$(mark_failure jwt_generation_failed)
  [ "$fails" -ge 3 ] && append_event chanakya appstore_watch_stuck "$TAG" \
    "{\"reason\":\"jwt_generation_failed\",\"failures\":$fails}" 2>/dev/null || true
  exit 1
}

RESPONSE=$(curl -sg --max-time 30 \
  "https://api.appstoreconnect.apple.com/v1/apps/$APP_ID/appStoreVersions?filter%5BversionString%5D=$VERSION&fields%5BappStoreVersions%5D=appStoreState" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null) || RESPONSE=""

STATE=$(python3 - <<PY 2>/dev/null
import json, sys
try:
    d = json.loads('''$RESPONSE''')
    print(d['data'][0]['attributes']['appStoreState'])
except Exception:
    sys.exit(2)
PY
)
if [ -z "$STATE" ]; then
  fails=$(mark_failure asc_query_failed)
  [ "$fails" -ge 3 ] && append_event chanakya appstore_watch_stuck "$TAG" \
    "{\"reason\":\"asc_query_failed\",\"failures\":$fails}" 2>/dev/null || true
  exit 1
fi

echo "[appstore-watch] $TAG → $STATE"

case "$STATE" in
  PENDING_DEVELOPER_RELEASE|READY_FOR_SALE)
    # Idempotent finalize driven by marker.finalize_progress.
    DRAFT_DONE=$(read_field finalize_draft_published)
    SLACK_DONE=$(read_field finalize_slack_posted)

    if [ "$DRAFT_DONE" != "True" ] && [ "$DRAFT_DONE" != "true" ]; then
      if gh release edit "$TAG" --repo "$REPO" --draft=false >/dev/null 2>&1; then
        python3 - "$MARKER" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m['finalize_draft_published'] = True
json.dump(m, open(p, 'w'), indent=2)
PY
      else
        fails=$(mark_failure gh_release_edit_failed "$STATE")
        [ "$fails" -ge 3 ] && append_event chanakya appstore_watch_stuck "$TAG" \
          "{\"reason\":\"gh_release_edit_failed\",\"failures\":$fails,\"state\":\"$STATE\"}" 2>/dev/null || true
        exit 1
      fi
    fi

    if [ "$SLACK_DONE" != "True" ] && [ "$SLACK_DONE" != "true" ]; then
      SLACK_TOKEN_FILE="$HOME/.claude/secrets/slack-bot-token"
      if [ -r "$SLACK_TOKEN_FILE" ] && [ -n "$PARENT_TS" ] && [ -n "$CHANNEL" ]; then
        SLACK_BOT_TOKEN=$(cat "$SLACK_TOKEN_FILE")
        MSG="🎉 Live on App Store — notes: $URL"
        BODY=$(python3 - "$CHANNEL" "$PARENT_TS" "$MSG" <<'PY'
import json, sys
print(json.dumps({'channel': sys.argv[1], 'thread_ts': sys.argv[2], 'text': sys.argv[3]}))
PY
)
        if curl -s --max-time 20 -X POST https://slack.com/api/chat.postMessage \
            -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$BODY" >/dev/null 2>&1; then
          python3 - "$MARKER" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m['finalize_slack_posted'] = True
json.dump(m, open(p, 'w'), indent=2)
PY
        else
          fails=$(mark_failure slack_post_failed "$STATE")
          [ "$fails" -ge 3 ] && append_event chanakya appstore_watch_stuck "$TAG" \
            "{\"reason\":\"slack_post_failed\",\"failures\":$fails,\"state\":\"$STATE\"}" 2>/dev/null || true
          exit 1
        fi
      else
        # No Slack config — mark as posted so we don't loop.
        python3 - "$MARKER" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m['finalize_slack_posted'] = True
m['finalize_slack_skipped_reason'] = 'no_token_or_ts'
json.dump(m, open(p, 'w'), indent=2)
PY
      fi
    fi

    rm -f "$MARKER"
    append_event chanakya appstore_released "$TAG" \
      "{\"final_state\":\"$STATE\",\"tag\":\"$TAG\"}" 2>/dev/null || true
    echo "[appstore-watch] finalized $TAG — marker deleted"
    ;;
  *)
    JITTER=$(( (RANDOM % 1801) + 1800 ))
    python3 - "$MARKER" "$STATE" "$NOW_ISO" "$JITTER" <<'PY'
import json, sys, datetime
p, state, now, jitter = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
m = json.load(open(p))
m['last_state'] = state
m['last_check_at'] = now
m['failures'] = 0
m.pop('stuck', None)
m.pop('last_error', None)
nxt = datetime.datetime.utcnow() + datetime.timedelta(seconds=jitter)
m['next_check_at'] = nxt.strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump(m, open(p, 'w'), indent=2)
PY
    append_event chanakya appstore_state_checked "$TAG" \
      "{\"state\":\"$STATE\"}" 2>/dev/null || true
    ;;
esac
