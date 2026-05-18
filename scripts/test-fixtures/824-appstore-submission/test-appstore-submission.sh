#!/usr/bin/env bash
# Smoke test for App Store submission ASC auth prerequisites.

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../.." && pwd)

TMPHOME=$(mktemp -d -t studio-appstore-submission-fixture-XXXXXX)
trap 'rm -rf "$TMPHOME"' EXIT

export HOME="$TMPHOME"
export ACHILLES_PROJECT="824-fixture"

NOTES="$TMPHOME/release-notes.md"
WHATSNEW="$TMPHOME/whats-new.txt"
printf 'Fixture release notes\n' >"$NOTES"
printf 'Fixture whats new\n' >"$WHATSNEW"

echo "=== Test 1: dry-run appstore path does not require ASC credentials ==="
OUT=$(STUDIO_TF_PUSH_SKIP_NODE_PICK=1 "$REPO/scripts/studio-tf-push.sh" appstore \
  --dry-run \
  --build 824 \
  --version 26.5.0 \
  --release-notes-file "$NOTES" \
  --whatsnew-file "$WHATSNEW" 2>&1)
printf '%s\n' "$OUT" | grep -q "would tag 824-zaps" \
  || { echo "FAIL: dry-run did not reach appstore dry-run output"; printf '%s\n' "$OUT"; exit 1; }
echo "PASS: dry-run remains side-effect free"

echo
echo "=== Test 2: Fastlane session env is not an ASC auth fallback ==="
set +e
OUT=$(STUDIO_TF_PUSH_LIVE=1 \
  FASTLANE_SESSION="fixture-fastlane-session" \
  FASTLANE_USER="fixture@example.com" \
  "$REPO/scripts/studio-tf-push.sh" appstore \
    --build 824 \
    --version 26.5.0 \
    --release-notes-file "$NOTES" \
    --whatsnew-file "$WHATSNEW" 2>&1)
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: appstore should reject missing ASC API credentials"; exit 1; }
printf '%s\n' "$OUT" | grep -q "STUDIO_TF_APP_ID missing" \
  || { echo "FAIL: missing ASC app-id message"; printf '%s\n' "$OUT"; exit 1; }
printf '%s\n' "$OUT" | grep -q "fastlane discovery/session auth is not an automatic fallback" \
  || { echo "FAIL: missing explicit no-Fastlane-fallback message"; printf '%s\n' "$OUT"; exit 1; }
echo "PASS: Fastlane env does not bypass ASC API credential prerequisites"

echo
echo "=== Test 3: READY_FOR_SALE updates the Slack parent message ==="
FIXTURE_BIN="$TMPHOME/bin"
FIXTURE_PY="$TMPHOME/python"
mkdir -p "$FIXTURE_BIN" "$FIXTURE_PY" \
  "$TMPHOME/.dev-studio/824-fixture/.runtime/state" \
  "$TMPHOME/.dev-studio/824-fixture/secrets/appstoreconnect"

cat >"$FIXTURE_PY/jwt.py" <<'PY'
def encode(payload, key, algorithm=None, headers=None):
    return "fixture-jwt"
PY

cat >"$FIXTURE_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$GH_CALL_FILE"
exit 0
SH
chmod +x "$FIXTURE_BIN/gh"

cat >"$FIXTURE_BIN/curl" <<'SH'
#!/usr/bin/env bash
url=""
body=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    http*) url="$1" ;;
    -d) shift; body="${1:-}" ;;
  esac
  shift || true
done
case "$url" in
  *appStoreVersions*)
    printf '{"data":[{"attributes":{"appStoreState":"READY_FOR_SALE"}}]}\n'
    ;;
  *chat.update*)
    printf '%s\n' "$url" >"$SLACK_URL_FILE"
    printf '%s\n' "$body" >"$SLACK_BODY_FILE"
    printf '{"ok":true,"ts":"1700000000.000100"}\n'
    ;;
  *chat.postMessage*)
    printf '%s\n' "$url" >"$SLACK_URL_FILE"
    printf '%s\n' "$body" >"$SLACK_BODY_FILE"
    printf '{"ok":true,"ts":"1700000000.000101"}\n'
    ;;
  *)
    printf 'unexpected curl url: %s\n' "$url" >&2
    exit 1
    ;;
esac
SH
chmod +x "$FIXTURE_BIN/curl"

printf 'fixture-token\n' >"$TMPHOME/.dev-studio/824-fixture/secrets/slack-bot-token"
printf 'fixture-key\n' >"$TMPHOME/.dev-studio/824-fixture/secrets/appstoreconnect/AuthKey_FIXTUREKEY.p8"

cat >"$TMPHOME/.dev-studio/824-fixture/.runtime/state/pending-appstore-review.json" <<JSON
{
  "project": "824-fixture",
  "next_check_at": "2000-01-01T00:00:00Z",
  "tag": "824-zaps",
  "version": "26.5.0",
  "asc_app_id": "fixture-app",
  "repo": "fixture/repo",
  "slack_channel": "C123",
  "slack_parent_ts": "1700000000.000100",
  "github_release_url": "https://github.com/fixture/repo/releases/tag/824-zaps",
  "asc_key_path": "$TMPHOME/.dev-studio/824-fixture/secrets/appstoreconnect/AuthKey_FIXTUREKEY.p8",
  "asc_issuer_id": "fixture-issuer",
  "asc_key_id": "FIXTUREKEY"
}
JSON

export PATH="$FIXTURE_BIN:$PATH"
export PYTHONPATH="$FIXTURE_PY${PYTHONPATH:+:$PYTHONPATH}"
export GH_CALL_FILE="$TMPHOME/gh-call.txt"
export SLACK_URL_FILE="$TMPHOME/slack-url.txt"
export SLACK_BODY_FILE="$TMPHOME/slack-body.json"

"$REPO/scripts/appstore-watch.sh" >"$TMPHOME/appstore-watch.out" 2>&1

grep -q "chat.update" "$SLACK_URL_FILE" \
  || { echo "FAIL: READY_FOR_SALE did not call chat.update"; cat "$TMPHOME/appstore-watch.out"; exit 1; }
jq -e '.ts == "1700000000.000100" and (.thread_ts | not)' "$SLACK_BODY_FILE" >/dev/null \
  || { echo "FAIL: Slack update body did not target the parent ts"; cat "$SLACK_BODY_FILE"; exit 1; }
[ ! -f "$TMPHOME/.dev-studio/824-fixture/.runtime/state/pending-appstore-review.json" ] \
  || { echo "FAIL: finalized JSON marker was not removed"; exit 1; }
grep -q "release edit 824-zaps --repo fixture/repo --draft=false" "$GH_CALL_FILE" \
  || { echo "FAIL: GitHub draft release was not published"; cat "$GH_CALL_FILE"; exit 1; }
echo "PASS: READY_FOR_SALE updates the original Slack parent"

echo
echo "All checks passed."
