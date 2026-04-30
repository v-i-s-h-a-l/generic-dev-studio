#!/usr/bin/env bash
# Smoke test for #288 Stage E.
#
# Verifies:
#   1. node-pick --requires-secret-scope asc,slack picks `fixture-laptop` from
#      a 3-node registry where only laptop advertises both scopes (mini and
#      third are filtered out — issue #288 step 5).
#   2. studio-tf-push.sh push --dry-run walks all four pre-Slack events
#      (release_started, archive_completed, upload_completed, dsym_uploaded)
#      and emits the JSON context blob on stdout.
#   3. studio-tf-push.sh emit slack_drafted | slack_sent | release_failed
#      reuses the captured release-tag.
#
# Per memory `feedback_smoke_test_synthetic_only.md`: this fixture creates an
# isolated $HOME so node-pick reads our synthetic registry, never the real
# `~/.dev-studio/.runtime/nodes.json`. Throwaway slug only.

set -e
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../.." && pwd)

TMPHOME=$(mktemp -d -t studio-tf-push-fixture-XXXXXX)
trap 'rm -rf "$TMPHOME"' EXIT

mkdir -p "$TMPHOME/.dev-studio/.runtime"
cp "$SCRIPT_DIR/nodes.json" "$TMPHOME/.dev-studio/.runtime/nodes.json"

export HOME="$TMPHOME"
export ACHILLES_PROJECT="288-fixture"
export DRY_RUN=1
export STUDIO_RELEASE_TAG="release-fixture-288"

echo "=== Test 1: scope filter narrows the 3-node registry to fixture-laptop ==="
# The full node-pick.sh runs health probes via node-health.sh, which won't
# resolve fictional fixture hosts. We test the secret-scope filter at the jq
# level — that's the #284/#288 invariant the issue is verifying. The filter
# expression mirrors node-pick.sh.
CANDIDATES=$(jq -r '
  ["asc","slack"] as $r
  | .nodes[]
  | select(.enabled != false)
  | select(.roles | index("release"))
  | select(($r - (.secret_scopes // [])) == [])
  | .id
' "$TMPHOME/.dev-studio/.runtime/nodes.json")
if [ "$CANDIDATES" != "fixture-laptop" ]; then
  echo "FAIL: scope filter expected only 'fixture-laptop', got: $CANDIDATES"
  exit 1
fi
echo "PASS: scope filter excluded fixture-mini + fixture-third, kept fixture-laptop"

echo
echo "=== Test 2: dry-run push walks all four pre-Slack events ==="
OUT=$(STUDIO_TF_PUSH_FIXTURE_NODE=fixture-laptop "$REPO/scripts/studio-tf-push.sh" push --dry-run 2>&1)
CTX=$(echo "$OUT" | tail -1)
echo "$OUT" | grep -q "DRY-RUN event release_started" || { echo "FAIL: missing release_started"; exit 1; }
echo "$OUT" | grep -q "DRY-RUN event archive_completed" || { echo "FAIL: missing archive_completed"; exit 1; }
echo "$OUT" | grep -q "DRY-RUN event upload_completed" || { echo "FAIL: missing upload_completed"; exit 1; }
echo "$OUT" | grep -q "DRY-RUN event dsym_uploaded" || { echo "FAIL: missing dsym_uploaded"; exit 1; }
RT=$(echo "$CTX" | jq -r .release_tag)
[ "$RT" = "release-fixture-288" ] || { echo "FAIL: release_tag mismatch ($RT)"; exit 1; }
echo "PASS: 4 events + context (release_tag=$RT)"

echo
echo "=== Test 3: emit subcommand reuses release-tag ==="
"$REPO/scripts/studio-tf-push.sh" emit slack_drafted --release-tag "$RT" \
  --data '{"build":1,"channel":"#testing","bullet_count":0,"cc_count":0}' >/dev/null
"$REPO/scripts/studio-tf-push.sh" emit slack_sent --release-tag "$RT" \
  --data '{"build":1,"channel":"#testing","parent_ts":"123.456","message_chars":10}' >/dev/null
echo "PASS: emit slack_drafted + slack_sent"

echo
echo "=== Test 4: bad emit args reject ==="
if "$REPO/scripts/studio-tf-push.sh" emit bogus --release-tag x --data '{}' 2>/dev/null; then
  echo "FAIL: bogus event should have rejected"; exit 1
fi
if "$REPO/scripts/studio-tf-push.sh" emit slack_sent --release-tag x --data 'not-json' 2>/dev/null; then
  echo "FAIL: invalid JSON should have rejected"; exit 1
fi
echo "PASS: invalid args rejected"

echo
echo "=== Test 5: live mode without STUDIO_TF_PUSH_LIVE halts ==="
unset DRY_RUN
if STUDIO_TF_PUSH_FIXTURE_NODE=fixture-laptop "$REPO/scripts/studio-tf-push.sh" push 2>/dev/null; then
  echo "FAIL: should have halted without STUDIO_TF_PUSH_LIVE=1"; exit 1
fi
echo "PASS: halted at prereq gate"

echo
echo "=== Test 6: failed push preflight leaves pbxproj untouched ==="
REAL_GIT=$(command -v git)
PROJECT="$TMPHOME/project"
PBX="$PROJECT/zaps-app/Turnip.xcodeproj/project.pbxproj"
mkdir -p "$(dirname "$PBX")" "$TMPHOME/bin"
cat > "$PBX" <<'PBX'
CURRENT_PROJECT_VERSION = 1;
MARKETING_VERSION = 1.0.0;
PBX
(
  cd "$PROJECT"
  "$REAL_GIT" init -q
  "$REAL_GIT" config user.email fixture@example.com
  "$REAL_GIT" config user.name Fixture
  "$REAL_GIT" add zaps-app/Turnip.xcodeproj/project.pbxproj
  "$REAL_GIT" commit -q -m "Initial fixture"
  "$REAL_GIT" checkout -q -b feature/testflight
  "$REAL_GIT" remote add origin https://github.com/example/private-fixture.git
)
cat > "$TMPHOME/bin/git" <<SH
#!/usr/bin/env bash
if [ "\$1" = "-C" ] && [ "\$3" = "push" ] && [ "\$4" = "--dry-run" ]; then
  echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$TMPHOME/bin/git"
if PATH="$TMPHOME/bin:$PATH" \
    STUDIO_TF_PUSH_LIVE=1 \
    STUDIO_TF_PUSH_SKIP_NODE_PICK=1 \
    STUDIO_RELEASE_TAG="release-fixture-362" \
    STUDIO_TF_PROJECT_ROOT="$PROJECT" \
    STUDIO_TF_PBXPROJ="$PBX" \
    "$REPO/scripts/studio-tf-push.sh" push >"$TMPHOME/preflight.out" 2>&1; then
  echo "FAIL: failed push preflight should halt"; exit 1
fi
grep -q "GitHub push auth/preflight failed before mutation" "$TMPHOME/preflight.out" \
  || { echo "FAIL: missing GitHub auth preflight message"; cat "$TMPHOME/preflight.out"; exit 1; }
grep -q "CURRENT_PROJECT_VERSION = 1;" "$PBX" || { echo "FAIL: build number mutated"; exit 1; }
grep -q "MARKETING_VERSION = 1.0.0;" "$PBX" || { echo "FAIL: marketing version mutated"; exit 1; }
if "$REAL_GIT" -C "$PROJECT" log --oneline --grep="Bump build number" | grep -q .; then
  echo "FAIL: build-number commit was created"; exit 1
fi
echo "PASS: push auth failure halted before mutation or commit"

echo
echo "=== Test 7: live-version lookup is app-scoped ==="
grep -q "/v1/apps/\${APP_ID}/appStoreVersions?filter\\[appStoreState\\]=READY_FOR_SALE" \
  "$REPO/scripts/studio-tf-push.sh" || { echo "FAIL: missing app-scoped live-version endpoint"; exit 1; }
if grep -q "/v1/appStoreVersions?filter\\[appStoreState\\]=READY_FOR_SALE" \
    "$REPO/scripts/studio-tf-push.sh"; then
  echo "FAIL: found forbidden top-level live-version endpoint"; exit 1
fi
grep -q "app_id.*6502945736" "$REPO/_shared/contracts/release-tf-push.md" \
  || { echo "FAIL: contract does not name app_id config value"; exit 1; }
echo "PASS: live-version endpoint is app-scoped and documented"

echo
echo "=== Test 8: empty live-version response halts before mutation ==="
cat > "$TMPHOME/bin/git" <<SH
#!/usr/bin/env bash
if [ "\$1" = "-C" ] && [ "\$3" = "push" ] && [ "\$4" = "--dry-run" ]; then
  exit 0
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$TMPHOME/bin/git"
cat > "$TMPHOME/bin/python3" <<'PY'
#!/usr/bin/env bash
cat >/dev/null
echo fixture-token
PY
chmod +x "$TMPHOME/bin/python3"
ASC_KEY="$TMPHOME/AuthKey_fixture.p8"
BUILDS_JSON="$TMPHOME/builds.json"
VERSIONS_JSON="$TMPHOME/versions-empty.json"
printf 'fixture-key\n' > "$ASC_KEY"
printf '{"data":[{"attributes":{"version":"41"}}]}\n' > "$BUILDS_JSON"
printf '{"data":[]}\n' > "$VERSIONS_JSON"
if PATH="$TMPHOME/bin:$PATH" \
    STUDIO_TF_PUSH_LIVE=1 \
    STUDIO_TF_PUSH_SKIP_NODE_PICK=1 \
    STUDIO_TF_SLACK_DEFERRED=1 \
    STUDIO_RELEASE_TAG="release-fixture-97" \
    STUDIO_TF_PROJECT_ROOT="$PROJECT" \
    STUDIO_TF_PBXPROJ="$PBX" \
    STUDIO_TF_ASC_KEY_PATH="$ASC_KEY" \
    STUDIO_TF_BUILDS_RESPONSE_FILE="$BUILDS_JSON" \
    STUDIO_TF_VERSIONS_RESPONSE_FILE="$VERSIONS_JSON" \
    "$REPO/scripts/studio-tf-push.sh" push >"$TMPHOME/empty-version.out" 2>&1; then
  echo "FAIL: empty live-version response should halt"; exit 1
fi
grep -q "WARNING: Could not determine live App Store version" "$TMPHOME/empty-version.out" \
  || { echo "FAIL: missing live-version warning"; cat "$TMPHOME/empty-version.out"; exit 1; }
grep -q "CURRENT_PROJECT_VERSION = 1;" "$PBX" || { echo "FAIL: build number mutated after empty live version"; exit 1; }
if "$REAL_GIT" -C "$PROJECT" log --oneline --grep="Bump build number" | grep -q .; then
  echo "FAIL: build-number commit was created after empty live version"; exit 1
fi
echo "PASS: empty live-version response is not treated as no conflict"

echo
echo "All checks passed."
