#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../.." && pwd)

push_doc="$REPO/commands/pushTFBuild.md"
appstore_doc="$REPO/commands/fullSendToAppStore.md"
contract="$REPO/_shared/contracts/release-tf-push.md"

echo "=== Test 1: command wrappers name ASC API-key auth as the default ==="
grep -q "Authentication is App Store Connect API key based" "$push_doc" \
  || { echo "FAIL: pushTFBuild.md does not name ASC API-key auth"; exit 1; }
grep -q "Authentication is App Store Connect API key based" "$appstore_doc" \
  || { echo "FAIL: fullSendToAppStore.md does not name ASC API-key auth"; exit 1; }
grep -q "STUDIO_TF_ASC_KEY_PATH" "$push_doc" \
  || { echo "FAIL: pushTFBuild.md does not document STUDIO_TF_ASC_KEY_PATH"; exit 1; }
grep -q "STUDIO_TF_ASC_KEY_PATH" "$appstore_doc" \
  || { echo "FAIL: fullSendToAppStore.md does not document STUDIO_TF_ASC_KEY_PATH"; exit 1; }
echo "PASS: wrappers point operators at ASC API-key auth"

echo
echo "=== Test 2: wrappers reject implicit session/Fastlane fallback ==="
grep -q "Session auth, fastlane discovery, and third-party credential schemes are not automatic fallbacks" "$push_doc" \
  || { echo "FAIL: pushTFBuild.md does not reject implicit fallbacks"; exit 1; }
grep -q "Session auth, fastlane discovery, and third-party credential schemes are not automatic fallbacks" "$appstore_doc" \
  || { echo "FAIL: fullSendToAppStore.md does not reject implicit fallbacks"; exit 1; }
grep -q "do not switch to session-based upload credentials" "$push_doc" \
  || { echo "FAIL: pushTFBuild.md lacks operator recovery guidance"; exit 1; }
grep -q "Do not switch to session-based upload credentials" "$appstore_doc" \
  || { echo "FAIL: fullSendToAppStore.md lacks operator recovery guidance"; exit 1; }
echo "PASS: wrappers make fallback behavior explicit"

echo
echo "=== Test 3: shared contract pins automatic auth to xcodebuild ASC key flags ==="
grep -q -- "-authenticationKeyPath.*-authenticationKeyID.*-authenticationKeyIssuerID" "$contract" \
  || { echo "FAIL: release contract does not pin automatic auth to xcodebuild ASC flags"; exit 1; }
grep -q "fastlane discovery, session auth, and third-party credential schemes are not prerequisites" "$contract" \
  || { echo "FAIL: release contract does not reject non-ASC automatic fallback schemes"; exit 1; }
echo "PASS: contract and wrappers agree on ASC API-key auth"

echo
echo "All checks passed."
