#!/usr/bin/env bash
# Regression coverage for App Store promotion approval recording.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t release-promotion-gate-702.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq required"
command -v yq >/dev/null 2>&1 || fail "yq required"

grep -Fq "pr-merge-finalize.sh\" \"\$pr_ref\"" "$ROOT/scripts/appstore-watch.sh" \
  || fail "appstore-watch does not delegate PR promotion to pr-merge-finalize"
grep -Fq -- "--release-id \"\$release_uuid\"" "$ROOT/scripts/appstore-watch.sh" \
  || fail "appstore-watch does not pass release id to approval writer"
if grep -Fq "gh pr merge \"\$PR_NUMBER\"" "$ROOT/scripts/appstore-watch.sh"; then
  fail "appstore-watch still merges App Store PRs directly"
fi
grep -Fq "release_id:\$release_id" "$ROOT/scripts/studio-tf-push.sh" \
  || fail "App Store marker does not carry release_id"

BIN="$TMPROOT/bin"
WORK="$TMPROOT/repo"
HOME_DIR="$TMPROOT/home"
PROJECT="release-promotion-gate-fixture"
RELEASES_DIR="$HOME_DIR/.dev-studio/$PROJECT/plans/releases"
MERGE_LOG="$TMPROOT/merge.log"
mkdir -p "$BIN" "$WORK" "$RELEASES_DIR"

cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

pr_json() {
  printf '{"number":123,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"release/appstore-fixture","headRefOid":"abc123","headRepositoryOwner":{"login":"owner"},"baseRefName":"main","url":"https://github.com/owner/repo/pull/123","commits":[{"oid":"abc123"}]}\n'
}

case "$1 $2" in
  "pr view")
    case " $* " in
      *" --json comments "*)
        case "${COMMENT_MODE:-approved}" in
          approved)
            jq -nc \
              --arg body '<!-- studio:pr-review-gate v1 -->
STUDIO_REVIEW_GATE=approved
HEAD_SHA=abc123' \
              --arg url 'https://github.com/owner/repo/pull/123#issuecomment-1' \
              '{body:$body,url:$url}'
            ;;
          missing) printf '{}\n' ;;
          *) printf 'unknown COMMENT_MODE\n' >&2; exit 2 ;;
        esac
        ;;
      *) pr_json ;;
    esac
    ;;
  "pr merge")
    printf '%s\n' "$*" >> "${MERGE_LOG:?}"
    ;;
  "pr comment")
    printf '%s\n' "$*" >> "${COMMENT_LOG:?}"
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN/gh"

export PATH="$BIN:$PATH"
export HOME="$HOME_DIR"
export ACHILLES_PROJECT="$PROJECT"
export MERGE_LOG
export COMMENT_LOG="$TMPROOT/comment.log"

(
  cd "$WORK" || exit 1
  git init -q
  git config user.email test@example.invalid
  git config user.name "Release Promotion Fixture"
  printf 'base\n' >README.md
  git add README.md
  git commit -q -m init
  git branch -M main
  git checkout -q -b feature
  printf 'feature\n' >feature.txt
  git add feature.txt
  git commit -q -m feature
  git checkout -q main
)

write_release() {
  local release_id="$1"
  ACHILLES_PROJECT="$PROJECT" bash -c '
    . "$1/scripts/lib-ledger.sh"
    write_appstore_release_submission_artifact "$2" "1.0.0" "42" "42-zaps" "abc123" \
      "https://github.com/owner/repo/releases/tag/42-zaps" "123" \
      "https://github.com/owner/repo/pull/123" "feature" \
      "app-id" "build-id" "version-id" "" "" "" "fixture summary" >/dev/null
  ' bash "$ROOT" "$release_id"
}

assert_release_approved() {
  local release_id="$1"
  local file="$RELEASES_DIR/$release_id.yaml"
  yq -e '
    .state == "approved" and
    .approved_by == "pr-merge-finalize" and
    .approval_review_head_sha == "abc123" and
    .approval_review_comment_url == "https://github.com/owner/repo/pull/123#issuecomment-1"
  ' "$file" >/dev/null || fail "release $release_id approval metadata was not recorded"
}

cd "$WORK" || exit 1
: >"$MERGE_LOG"
write_release rel-approval-only
COMMENT_MODE=approved bash "$ROOT/scripts/pr-merge-finalize.sh" 123 \
  --release-id rel-approval-only \
  --record-release-approval-only \
  --expected-head-sha abc123 >"$TMPROOT/approval-only.out"
grep -Fq 'RELEASE_APPROVED=1' "$TMPROOT/approval-only.out" || fail "approval-only mode did not report approval"
grep -Fq 'PR_MERGED=0' "$TMPROOT/approval-only.out" || fail "approval-only mode reported a merge"
[ ! -s "$MERGE_LOG" ] || fail "approval-only mode called gh pr merge"
assert_release_approved rel-approval-only

write_release rel-missing-comment
if COMMENT_MODE=missing bash "$ROOT/scripts/pr-merge-finalize.sh" 123 \
    --release-id rel-missing-comment \
    --record-release-approval-only >"$TMPROOT/missing.out" 2>"$TMPROOT/missing.err"; then
  fail "missing review-gate comment unexpectedly recorded approval"
fi
yq -e '.state == "submitted" and .approval_review_head_sha == null' \
  "$RELEASES_DIR/rel-missing-comment.yaml" >/dev/null \
  || fail "missing-comment path mutated the release artifact"
grep -Fq 'no approved studio review gate comment found' "$TMPROOT/missing.err" \
  || fail "missing-comment error did not name the review gate"

: >"$MERGE_LOG"
write_release rel-target-lock
COMMENT_MODE=approved bash "$ROOT/scripts/pr-merge-finalize.sh" 123 \
  --release-id rel-target-lock \
  --method merge >"$TMPROOT/target-lock.out" 2>"$TMPROOT/target-lock.err" && fail "target repo release merge unexpectedly bypassed auto-merge lock"
grep -Fq 'PR_MERGED=0' "$TMPROOT/target-lock.out" || fail "target repo release lock did not report PR_MERGED=0"
[ ! -s "$MERGE_LOG" ] || fail "target repo release lock called gh pr merge"
assert_release_approved rel-target-lock

: >"$MERGE_LOG"
write_release rel-merge
COMMENT_MODE=approved STUDIO_TARGET_REPO_AUTO_MERGE=1 bash "$ROOT/scripts/pr-merge-finalize.sh" 123 \
  --release-id rel-merge \
  --method merge >"$TMPROOT/merge.out" 2>"$TMPROOT/merge.err"
grep -Fq 'PR_MERGED=1' "$TMPROOT/merge.out" || fail "merge path did not report PR_MERGED=1"
grep -Fq -- '--merge' "$MERGE_LOG" || fail "merge path did not call gh pr merge --merge"
assert_release_approved rel-merge

printf 'PASS: release promotion gate\n'
