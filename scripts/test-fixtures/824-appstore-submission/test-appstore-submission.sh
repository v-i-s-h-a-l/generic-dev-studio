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
echo "All checks passed."
