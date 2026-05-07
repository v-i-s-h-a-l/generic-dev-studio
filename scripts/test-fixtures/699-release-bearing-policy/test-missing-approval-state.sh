#!/usr/bin/env bash
# Fixture: missing HEAD-bound approval state blocks release approval recording.

set -eu
umask 022

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/scripts/test-fixtures/699-release-bearing-policy/helpers.sh"

TMPROOT=$(mktemp -d -t release-bearing-policy-approval.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

release_policy_require_jq
release_policy_require_yq

BIN="$TMPROOT/bin"
WORK="$TMPROOT/repo"
HOME_DIR="$TMPROOT/home"
PROJECT="release-bearing-policy-approval-fixture"
RELEASES_DIR="$HOME_DIR/.dev-studio/$PROJECT/plans/releases"
mkdir -p "$BIN" "$WORK" "$RELEASES_DIR"

cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

pr_json() {
  printf '{"number":69903,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"feature/release-bearing-policy-approval","headRefOid":"abc699","headRepositoryOwner":{"login":"owner"},"baseRefName":"main","url":"https://github.com/owner/repo/pull/69903","commits":[{"oid":"abc699"}]}\n'
}

case "$1 $2" in
  "pr view")
    case " $* " in
      *" --json comments "*) printf '{}\n' ;;
      *) pr_json ;;
    esac
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN/gh"

(
  cd "$WORK" || exit 1
  git init -q
  git config user.email test@example.invalid
  git config user.name "Release Policy Fixture"
  printf 'base\n' >README.md
  git add README.md
  git commit -q -m init
  git branch -M main
  git checkout -q -b feature/release-bearing-policy-approval
  printf 'feature\n' >feature.txt
  git add feature.txt
  git commit -q -m feature
  git checkout -q main
)

HOME="$HOME_DIR" ACHILLES_PROJECT="$PROJECT" bash -c '
  . "$1/scripts/lib-ledger.sh"
  write_appstore_release_submission_artifact "rel-699-missing-approval" "1.0.0" "699" "699-release" "abc699" \
    "https://github.com/owner/repo/releases/tag/699-release" "69903" \
    "https://github.com/owner/repo/pull/69903" "feature/release-bearing-policy-approval" \
    "app-id" "build-id" "version-id" "" "" "" "fixture summary" >/dev/null
' bash "$ROOT"

cd "$WORK" || exit 1
if PATH="$BIN:$PATH" HOME="$HOME_DIR" ACHILLES_PROJECT="$PROJECT" \
    bash "$ROOT/scripts/pr-merge-finalize.sh" 69903 \
      --release-id rel-699-missing-approval \
      --record-release-approval-only >"$TMPROOT/missing-approval.out" 2>"$TMPROOT/missing-approval.err"; then
  release_policy_fail "missing approval state unexpectedly recorded release approval"
fi

grep -Fq 'no approved studio review gate comment found' "$TMPROOT/missing-approval.err" \
  || release_policy_fail "missing approval error did not name the review gate"
yq -e '
  .state == "submitted"
  and .approval_review_head_sha == null
  and .approval_review_comment_url == null
  and .approved_by == null
' "$RELEASES_DIR/rel-699-missing-approval.yaml" >/dev/null \
  || release_policy_fail "missing approval path mutated the release artifact"

printf 'PASS: missing release approval state fixture\n'
