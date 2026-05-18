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
#   2. Slack closeout on the original #releases message
#   3. Queue Crashlytics closeout items once the app is live
#   4. Delete marker
#   5. Emit appstore_released
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
# shellcheck source=lib-release-config.sh
. "$SCRIPT_DIR/lib-release-config.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

PROJECT=$(resolve_project 2>/dev/null) || exit 0
STUDIO_RELEASE_PROJECT="${STUDIO_RELEASE_PROJECT:-$PROJECT}"
load_release_config || exit 0
ROOT=$(resolve_project_root_for "$PROJECT")
MARKER="$ROOT/.runtime/state/pending-appstore-review.json"
MARKER_SOURCE=json
ACTIVE_RELEASE_FILE=""
if [ ! -f "$MARKER" ]; then
  releases_dir="$ROOT/plans/releases"
  if [ ! -d "$releases_dir" ]; then
    exit 0
  fi
  active_count=$(yq -r 'select(.channel == "appstore" and (.state == "submitted" or .state == "in-review" or .state == "pending-developer-release")) | .id' "$releases_dir"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
  if [ "$active_count" = "0" ]; then
    exit 0
  fi
  if [ "$active_count" != "1" ]; then
    append_event chanakya appstore_watch_stuck "" \
      "{\"reason\":\"ambiguous_active_appstore_releases\",\"count\":$active_count}" 2>/dev/null || true
    echo "[appstore-watch] multiple active App Store releases; refusing to pick one" >&2
    exit 1
  fi
  ACTIVE_RELEASE_FILE=$(grep -lE '^channel: appstore$' "$releases_dir"/*.yaml 2>/dev/null | while IFS= read -r f; do
    state=$(yq -r '.state // ""' "$f" 2>/dev/null)
    if [ "$state" = "submitted" ] || [ "$state" = "in-review" ] || [ "$state" = "pending-developer-release" ]; then
      printf '%s\n' "$f"
    fi
  done | head -1)
  [ -n "$ACTIVE_RELEASE_FILE" ] || exit 0
  MARKER_SOURCE=yaml
fi

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

py() { python3 -c "$1" "$@"; }

read_field() {
  if [ "$MARKER_SOURCE" = "yaml" ]; then
    case "$1" in
      project) printf '%s\n' "$PROJECT" ;;
      next_check_at) yq -r '.asc_metadata.next_check_at // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null ;;
      tag) yq -r '.tag // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null ;;
      version) yq -r '.version // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null ;;
      asc_app_id) yq -r '.asc_metadata.asc_app_id // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null ;;
      repo) yq -r '.repo // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null ;;
      slack_channel) yq -r '.slack.posted_to // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null ;;
      slack_parent_ts) yq -r '.slack.message_ts // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null ;;
      github_release_url) yq -r '.github_release_url // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null ;;
      crash_fixes) yq -o=json '.crash_fixes // .asc_metadata.crash_fixes // []' "$ACTIVE_RELEASE_FILE" 2>/dev/null ;;
      asc_key_path) printf '%s\n' "${STUDIO_TF_ASC_KEY_PATH:-}" ;;
      asc_issuer_id) printf '%s\n' "${STUDIO_TF_ASC_ISSUER_ID:-}" ;;
      asc_key_id) printf '%s\n' "${STUDIO_TF_ASC_KEY_ID:-}" ;;
      finalize_draft_published) yq -r '.asc_metadata.finalize_draft_published // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null ;;
      finalize_slack_posted) yq -r '.asc_metadata.finalize_slack_posted // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null ;;
      *) printf '\n' ;;
    esac
    return 0
  fi
  python3 - "$MARKER" "$1" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
except Exception:
    v = ""
print(v if v is not None else "")
PY
}

read_json_field() {
  local field="$1" value
  if [ "$MARKER_SOURCE" = "json" ]; then
    jq -c --arg field "$field" '.[$field] // []' "$MARKER" 2>/dev/null || printf '[]\n'
    return 0
  fi
  value=$(read_field "$field")
  if printf '%s\n' "$value" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$value" | jq -c .
  else
    printf '[]\n'
  fi
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

APP_ID="${APP_ID:-${STUDIO_TF_APP_ID:-}}"
REPO="${REPO:-${STUDIO_TF_GH_REPO:-turnip-ios/turnip-zaps}}"
URL="${URL:-https://github.com/${REPO}/releases/tag/${TAG}}"
KEY_ID="${KEY_ID:-${STUDIO_TF_ASC_KEY_ID:-}}"
ISSUER_ID="${ISSUER_ID:-${STUDIO_TF_ASC_ISSUER_ID:-}}"
if [ -z "$KEY_PATH" ]; then
  KEY_PATH=$(release_asc_key_path "$KEY_ID" 2>/dev/null || true)
fi

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

CRASH_FIXES_JSON=$(read_json_field crash_fixes)

queue_crashlytics_closeouts() {
  [ "${STATE:-}" = "READY_FOR_SALE" ] || return 0
  [ -n "$CRASH_FIXES_JSON" ] || return 0

  local queue
  queue=$(resolve_push_queue) || return 1
  python3 - "$queue" "$TAG" "$VERSION" "$CRASH_FIXES_JSON" <<'PY'
import datetime
import hashlib
import json
import os
import sys

queue, tag, version, raw = sys.argv[1:5]
try:
    crashes = json.loads(raw)
except json.JSONDecodeError:
    crashes = []
if not isinstance(crashes, list):
    crashes = []

existing = set()
try:
    with open(queue, encoding="utf-8") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            entry_id = entry.get("id")
            if entry_id:
                existing.add(str(entry_id))
except FileNotFoundError:
    pass

rows = []
for crash in crashes:
    if not isinstance(crash, dict):
        continue
    status = str(crash.get("crashlytics_closeout") or crash.get("closeout") or "queued")
    if status in {"annotated", "skipped"}:
        continue
    url = str(crash.get("public_crash_url") or crash.get("crash_url") or crash.get("url") or "")
    if not url:
        continue
    label = str(crash.get("public_label") or crash.get("label") or "")
    digest = hashlib.sha1(f"{tag}\0{url}".encode("utf-8")).hexdigest()[:16]
    entry_id = f"crashlytics-closeout-{digest}"
    if entry_id in existing:
        continue
    prefix = f"Close Crashlytics for {tag} ({version}): "
    detail = f"{label}: {url}" if label else url
    text = prefix + detail
    if len(text) > 200:
        text = f"Close Crashlytics for {tag}: {url}"
    if len(text) > 200:
        text = text[:197].rstrip() + "..."
    rows.append({
        "id": entry_id,
        "ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "chanakya",
        "kind": "crashlytics_closeout",
        "task": tag,
        "text": text,
        "displayed": False,
    })
    existing.add(entry_id)

if rows:
    os.makedirs(os.path.dirname(queue), exist_ok=True)
    with open(queue, "a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
}

# Bump failure counter, update cadence, optionally mark stuck. Reused across
# all error paths. Args: <reason> [<partial-state>]
mark_failure() {
  local reason="$1" partial="${2:-}"
  if [ "$MARKER_SOURCE" = "yaml" ] && [ -n "$ACTIVE_RELEASE_FILE" ]; then
    local release_uuid failures next_iso stuck
    release_uuid=$(yq -r '.id // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null)
    failures=$(yq -r '.asc_metadata.consecutive_failures // 0' "$ACTIVE_RELEASE_FILE" 2>/dev/null)
    case "$failures" in ''|*[!0-9]*) failures=0 ;; esac
    failures=$((failures + 1))
    next_iso=$(python3 - <<'PY'
import datetime
print((datetime.datetime.utcnow() + datetime.timedelta(minutes=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
)
    stuck=false
    [ "$failures" -ge 3 ] && stuck=true
    [ -n "$release_uuid" ] && set_release_asc_failure "$release_uuid" "$reason" "$NOW_ISO" "$next_iso" "$failures" "$stuck" || true
    printf '%s\n' "$failures"
    return 0
  fi
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

# Generate ASC JWT (pattern from _shared/primitives/appstore-connect-jwt.md).
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

release_uuid=""
release_state=""
if [ "$MARKER_SOURCE" = "yaml" ] && [ -n "$ACTIVE_RELEASE_FILE" ]; then
  release_uuid=$(yq -r '.id // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null)
  release_state=$(yq -r '.state // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null)
fi
target_release_state=""
case "$STATE" in
  WAITING_FOR_REVIEW|IN_REVIEW) target_release_state="in-review" ;;
  PENDING_DEVELOPER_RELEASE) target_release_state="pending-developer-release" ;;
esac
if [ -n "$release_uuid" ]; then
  case "$target_release_state" in
    in-review|pending-developer-release|released)
      [ "$release_state" = "$target_release_state" ] || transition_release_state "$release_uuid" "$target_release_state" chanakya "ASC state $STATE" || true
      ;;
  esac
fi

case "$STATE" in
  PENDING_DEVELOPER_RELEASE|READY_FOR_SALE)
    # Idempotent finalize driven by marker.finalize_progress.
    DRAFT_DONE=$(read_field finalize_draft_published)
    SLACK_DONE=$(read_field finalize_slack_posted)

    if [ "$DRAFT_DONE" != "True" ] && [ "$DRAFT_DONE" != "true" ]; then
      if gh release edit "$TAG" --repo "$REPO" --draft=false >/dev/null 2>&1; then
        if [ "$MARKER_SOURCE" = "json" ]; then
          python3 - "$MARKER" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m['finalize_draft_published'] = True
json.dump(m, open(p, 'w'), indent=2)
PY
        else
          [ -n "$release_uuid" ] && set_release_finalize_progress "$release_uuid" finalize_draft_published true || true
        fi
      else
        fails=$(mark_failure gh_release_edit_failed "$STATE")
        [ "$fails" -ge 3 ] && append_event chanakya appstore_watch_stuck "$TAG" \
          "{\"reason\":\"gh_release_edit_failed\",\"failures\":$fails,\"state\":\"$STATE\"}" 2>/dev/null || true
        exit 1
      fi
    fi

    if [ "$SLACK_DONE" != "True" ] && [ "$SLACK_DONE" != "true" ]; then
      SLACK_TOKEN_FILE=$(release_slack_token_file)
      if [ -r "$SLACK_TOKEN_FILE" ] && [ -n "$PARENT_TS" ] && [ -n "$CHANNEL" ]; then
        SLACK_BOT_TOKEN=$(cat "$SLACK_TOKEN_FILE")
        MSG="🎉 Live on App Store — notes: $URL"
        if [ "$STATE" = "READY_FOR_SALE" ]; then
          SLACK_ENDPOINT=https://slack.com/api/chat.update
          BODY=$(python3 - "$CHANNEL" "$PARENT_TS" "$MSG" <<'PY'
import json, sys
print(json.dumps({'channel': sys.argv[1], 'ts': sys.argv[2], 'text': sys.argv[3]}))
PY
)
        else
          SLACK_ENDPOINT=https://slack.com/api/chat.postMessage
          BODY=$(python3 - "$CHANNEL" "$PARENT_TS" "$MSG" <<'PY'
import json, sys
print(json.dumps({'channel': sys.argv[1], 'thread_ts': sys.argv[2], 'text': sys.argv[3]}))
PY
)
        fi
        if curl -s --max-time 20 -X POST "$SLACK_ENDPOINT" \
            -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$BODY" >/dev/null 2>&1; then
          if [ "$MARKER_SOURCE" = "json" ]; then
            python3 - "$MARKER" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m['finalize_slack_posted'] = True
json.dump(m, open(p, 'w'), indent=2)
PY
          else
            [ -n "$release_uuid" ] && set_release_finalize_progress "$release_uuid" finalize_slack_posted true || true
          fi
        else
          fails=$(mark_failure slack_post_failed "$STATE")
          [ "$fails" -ge 3 ] && append_event chanakya appstore_watch_stuck "$TAG" \
            "{\"reason\":\"slack_post_failed\",\"failures\":$fails,\"state\":\"$STATE\"}" 2>/dev/null || true
          exit 1
        fi
      else
        # No Slack config — mark as posted so we don't loop.
        if [ "$MARKER_SOURCE" = "json" ]; then
          python3 - "$MARKER" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m['finalize_slack_posted'] = True
m['finalize_slack_skipped_reason'] = 'no_token_or_ts'
json.dump(m, open(p, 'w'), indent=2)
PY
        else
          if [ -n "$release_uuid" ]; then
            set_release_finalize_progress "$release_uuid" finalize_slack_posted true || true
            set_release_finalize_progress "$release_uuid" finalize_slack_skipped_reason no_token_or_ts || true
          fi
        fi
      fi
    fi

    if ! queue_crashlytics_closeouts; then
      fails=$(mark_failure crashlytics_closeout_queue_failed "$STATE")
      [ "$fails" -ge 3 ] && append_event chanakya appstore_watch_stuck "$TAG" \
        "{\"reason\":\"crashlytics_closeout_queue_failed\",\"failures\":$fails,\"state\":\"$STATE\"}" 2>/dev/null || true
      exit 1
    fi
    [ "$MARKER_SOURCE" = "json" ] && rm -f "$MARKER"
    if [ -n "$release_uuid" ]; then
      release_state=$(yq -r '.state // ""' "$ACTIVE_RELEASE_FILE" 2>/dev/null)
      [ "$release_state" = "released" ] || transition_release_state "$release_uuid" released chanakya "ASC state $STATE finalized" || true
    fi
    [ -n "$release_uuid" ] && set_release_asc_poll "$release_uuid" "$STATE" "$NOW_ISO" "$NOW_ISO" 0 false || true
    append_event chanakya appstore_released "$TAG" \
      "$(jq -cn --arg state "$STATE" --arg tag "$TAG" --arg version "$VERSION" --argjson crashes "$CRASH_FIXES_JSON" '{final_state:$state,tag:$tag,version:$version,crash_fixes:($crashes | map(. + {crashlytics_closeout:(.crashlytics_closeout // .closeout // "queued")}))}')" 2>/dev/null || true
    echo "[appstore-watch] finalized $TAG — marker reconciled"
    ;;
  *)
    JITTER=$(( (RANDOM % 1801) + 1800 ))
    NEXT_ISO=$(python3 - "$JITTER" <<'PY'
import sys, datetime
jitter = int(sys.argv[1])
nxt = datetime.datetime.utcnow() + datetime.timedelta(seconds=jitter)
print(nxt.strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
)
    if [ "$MARKER_SOURCE" = "json" ]; then
      python3 - "$MARKER" "$STATE" "$NOW_ISO" "$NEXT_ISO" <<'PY'
import json, sys, datetime
p, state, now, nxt = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
m = json.load(open(p))
m['last_state'] = state
m['last_check_at'] = now
m['failures'] = 0
m.pop('stuck', None)
m.pop('last_error', None)
m['next_check_at'] = nxt
json.dump(m, open(p, 'w'), indent=2)
PY
    fi
    [ -n "$release_uuid" ] && set_release_asc_poll "$release_uuid" "$STATE" "$NOW_ISO" "$NEXT_ISO" 0 false || true
    append_event chanakya appstore_state_checked "$TAG" \
      "{\"state\":\"$STATE\"}" 2>/dev/null || true
    ;;
esac
