#!/usr/bin/env bash
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../.." && pwd)

TMPHOME=$(mktemp -d -t studio-release-configure-XXXXXX)
trap 'rm -rf "$TMPHOME"' EXIT

export HOME="$TMPHOME"
export ACHILLES_PROJECT="fixture-ios"

NOTES="$TMPHOME/release-notes.txt"
WHATSNEW="$TMPHOME/whats-new.txt"
printf '*New*\n• Fixture release\n' >"$NOTES"
printf 'Fixture release notes for App Store users.\n' >"$WHATSNEW"

echo "=== Test 1: App Store Slack config writes opt-in release.env settings ==="
"$REPO/scripts/release-manager-configure.sh" \
  --project fixture-ios \
  --quick \
  --disable-testflight \
  --appstore-slack-channel CAPPSTORE123 \
  --appstore-slack-channel-name '#releases' \
  --no-appstore-github-reply

CONFIG="$TMPHOME/.dev-studio/fixture-ios/config/release.env"
grep -q "STUDIO_RELEASES_SLACK_CHANNEL='CAPPSTORE123'" "$CONFIG" || { echo "FAIL: missing App Store channel"; exit 1; }
grep -q "STUDIO_RELEASES_SLACK_CHANNEL_NAME='#releases'" "$CONFIG" || { echo "FAIL: missing channel name"; exit 1; }
grep -q "STUDIO_RELEASES_SLACK_APPSTORE_PARENT='1'" "$CONFIG" || { echo "FAIL: missing parent default"; exit 1; }
grep -q "STUDIO_RELEASES_SLACK_WHATSNEW_REPLY='1'" "$CONFIG" || { echo "FAIL: missing whats-new default"; exit 1; }
grep -q "STUDIO_RELEASES_SLACK_GITHUB_REPLY='0'" "$CONFIG" || { echo "FAIL: missing disabled GitHub reply"; exit 1; }
grep -q "STUDIO_RELEASES_SLACK_WATCHER_REPLIES='1'" "$CONFIG" || { echo "FAIL: missing watcher default"; exit 1; }
if grep -q "STUDIO_TF_SLACK_CHANNEL" "$CONFIG"; then
  echo "FAIL: disabled TestFlight should not write TF Slack settings"; exit 1
fi
echo "PASS: App Store release Slack settings persisted"

echo
echo "=== Test 2: dry-run App Store submission announces configured Slack shape without posting ==="
OUT=$(STUDIO_RELEASE_PROJECT=fixture-ios STUDIO_TF_PUSH_FIXTURE_NODE=fixture-laptop \
  "$REPO/scripts/studio-tf-push.sh" appstore \
    --dry-run \
    --build 123 \
    --version 26.5.0 \
    --release-notes-file "$NOTES" \
    --whatsnew-file "$WHATSNEW" 2>&1)
echo "$OUT" | grep -q "would post App Store Slack parent to CAPPSTORE123" || { echo "FAIL: missing parent dry-run"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "would post App Store What's New as a thread reply" || { echo "FAIL: missing whats-new dry-run"; echo "$OUT"; exit 1; }
if echo "$OUT" | grep -q "would post GitHub release URL"; then
  echo "FAIL: GitHub dry-run should honor disabled reply"; echo "$OUT"; exit 1
fi
echo "PASS: appstore dry-run consumes configured Slack settings"

echo
echo "=== Test 3: missing Slack config skips cleanly ==="
OUT=$(STUDIO_RELEASE_PROJECT=missing-ios STUDIO_TF_PUSH_FIXTURE_NODE=fixture-laptop \
  "$REPO/scripts/studio-tf-push.sh" appstore \
    --dry-run \
    --build 124 \
    --version 26.5.1 \
    --release-notes-file "$NOTES" \
    --whatsnew-file "$WHATSNEW" 2>&1)
echo "$OUT" | grep -q "Slack release announcements not configured; skipping Slack post" || { echo "FAIL: missing clean skip note"; echo "$OUT"; exit 1; }
echo "PASS: unconfigured App Store Slack path skips without failing"

echo
echo "All checks passed."
