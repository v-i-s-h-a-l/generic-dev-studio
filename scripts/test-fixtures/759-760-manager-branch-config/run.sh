#!/usr/bin/env bash
# Regression fixture for manager feature config and release branch workflow.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CONFIG="$ROOT/scripts/manager-feature-config.sh"
BRANCH="$ROOT/scripts/manager-release-branch.sh"
TMPROOT=$(mktemp -d -t manager-branch-config.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$CONFIG" ] || fail "manager-feature-config.sh is not executable"
[ -x "$BRANCH" ] || fail "manager-release-branch.sh is not executable"

echo "=== feature config: required inputs and dry-run ==="
FEATURE_CONFIG_FILE="$TMPROOT/features.env"
if HOME="$TMPROOT/home" ACHILLES_PROJECT=fixture-ios STUDIO_FEATURE_CONFIG_FILE="$FEATURE_CONFIG_FILE" "$CONFIG" enable release_branch_workflow >"$TMPROOT/enable-missing.out" 2>&1; then
  fail "enable without required inputs should fail"
fi
grep -q 'missing required input' "$TMPROOT/enable-missing.out" \
  || fail "missing-input error not reported"

HOME="$TMPROOT/home" ACHILLES_PROJECT=fixture-ios STUDIO_FEATURE_CONFIG_FILE="$FEATURE_CONFIG_FILE" "$CONFIG" enable release_branch_workflow \
  --default-release-base main \
  --branch-pattern 'release/{version}' \
  --dry-run >"$TMPROOT/enable-dry-run.out"
grep -q "STUDIO_FEATURE_RELEASE_BRANCH_WORKFLOW='1'" "$TMPROOT/enable-dry-run.out" \
  || fail "dry-run did not print feature enable write"
[ ! -e "$FEATURE_CONFIG_FILE" ] \
  || fail "dry-run wrote feature config"

HOME="$TMPROOT/home" ACHILLES_PROJECT=fixture-ios STUDIO_FEATURE_CONFIG_FILE="$FEATURE_CONFIG_FILE" "$CONFIG" enable release_branch_workflow \
  --default-release-base main \
  --branch-pattern 'release/{version}' >"$TMPROOT/enable.out"
CONFIG_FILE="$FEATURE_CONFIG_FILE"
grep -q "STUDIO_FEATURE_RELEASE_BRANCH_WORKFLOW='1'" "$CONFIG_FILE" \
  || fail "feature enable not persisted"
HOME="$TMPROOT/home" ACHILLES_PROJECT=fixture-ios STUDIO_FEATURE_CONFIG_FILE="$FEATURE_CONFIG_FILE" "$CONFIG" doctor >"$TMPROOT/doctor.out"
grep -q 'OK release_branch_workflow enabled' "$TMPROOT/doctor.out" \
  || fail "doctor did not report enabled feature as OK"
HOME="$TMPROOT/home" ACHILLES_PROJECT=fixture-ios STUDIO_FEATURE_CONFIG_FILE="$FEATURE_CONFIG_FILE" "$CONFIG" disable release_branch_workflow >/dev/null
grep -q "STUDIO_FEATURE_RELEASE_BRANCH_WORKFLOW='0'" "$CONFIG_FILE" \
  || fail "feature disable not persisted"

echo "=== release branch: missing/existing branch preflight ==="
ORIGIN="$TMPROOT/origin.git"
REPO="$TMPROOT/repo"
git init --bare "$ORIGIN" >/dev/null
git init -b main "$REPO" >/dev/null
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name "Manager Branch Fixture"
printf 'base\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -m 'base' >/dev/null
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -u origin main >/dev/null 2>&1

git -C "$REPO" checkout -b feature/clean main >/dev/null
printf 'feature\n' > "$REPO/feature.txt"
git -C "$REPO" add feature.txt
git -C "$REPO" commit -m 'feature clean' >/dev/null
git -C "$REPO" push -u origin feature/clean >/dev/null 2>&1
git -C "$REPO" checkout main >/dev/null

if HOME="$TMPROOT/home" "$BRANCH" --repo "$REPO" status --source feature/clean --target release/1.0 >"$TMPROOT/status-missing.out" 2>&1; then
  fail "status should return non-zero when target branch is missing"
fi
grep -q 'target: release/1.0 exists no' "$TMPROOT/status-missing.out" \
  || fail "missing target branch not reported"

HOME="$TMPROOT/home" "$BRANCH" --repo "$REPO" prepare-release --release 1.0 --from main --dry-run >"$TMPROOT/prepare-dry-run.out"
grep -q 'dry-run: would create release/1.0 from main' "$TMPROOT/prepare-dry-run.out" \
  || fail "prepare dry-run did not report create plan"
if git -C "$REPO" ls-remote --exit-code --heads origin release/1.0 >/dev/null 2>&1; then
  fail "prepare dry-run created remote branch"
fi

HOME="$TMPROOT/home" "$BRANCH" --repo "$REPO" prepare-release --release 1.0 --from main --create >"$TMPROOT/prepare-create.out"
grep -q 'status: created' "$TMPROOT/prepare-create.out" \
  || fail "prepare --create did not report created"
git -C "$REPO" ls-remote --exit-code --heads origin release/1.0 >/dev/null 2>&1 \
  || fail "release branch was not pushed"

HOME="$TMPROOT/home" "$BRANCH" --repo "$REPO" sync --source feature/clean --target release/1.0 >"$TMPROOT/sync-clean.out"
grep -q 'mergeability: clean' "$TMPROOT/sync-clean.out" \
  || fail "clean sync was not reported as clean"

echo "=== release branch: conflict halt ==="
git -C "$REPO" checkout -b release/conflict main >/dev/null
printf 'target\n' > "$REPO/conflict.txt"
git -C "$REPO" add conflict.txt
git -C "$REPO" commit -m 'target conflict file' >/dev/null
git -C "$REPO" push -u origin release/conflict >/dev/null 2>&1
git -C "$REPO" checkout -b feature/conflict main >/dev/null
printf 'source\n' > "$REPO/conflict.txt"
git -C "$REPO" add conflict.txt
git -C "$REPO" commit -m 'source conflict file' >/dev/null
git -C "$REPO" push -u origin feature/conflict >/dev/null 2>&1
git -C "$REPO" checkout main >/dev/null

if HOME="$TMPROOT/home" "$BRANCH" --repo "$REPO" sync --source feature/conflict --target release/conflict >"$TMPROOT/sync-conflict.out" 2>&1; then
  fail "conflicting sync should fail"
fi
grep -q 'mergeability: conflicts' "$TMPROOT/sync-conflict.out" \
  || fail "conflict mergeability not reported"
grep -q 'conflict.txt' "$TMPROOT/sync-conflict.out" \
  || fail "conflict file not reported"

printf 'PASS: manager branch/config workflow\n'
