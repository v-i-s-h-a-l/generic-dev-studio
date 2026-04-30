#!/usr/bin/env bash
# Verifies pr-merge-finalize auto method selection without calling GitHub.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t pr-merge-method.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
WORK="$TMPROOT/repo"
mkdir -p "$BIN" "$WORK"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -u

json_payload() {
  local n="${COMMIT_COUNT:-1}" base="${BASE_REF:-main}" commits="" i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$i" -gt 0 ]; then commits="$commits,"; fi
    commits="${commits}{\"oid\":\"c$i\"}"
    i=$((i + 1))
  done
  printf '{"number":123,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"feature","headRefOid":"abc123","headRepositoryOwner":{"login":"owner"},"baseRefName":"%s","url":"https://github.com/owner/repo/pull/123","commits":[%s]}\n' "$base" "$commits"
}

case "$1 $2" in
  "pr view")
    case " $* " in
      *" --jq "*) printf '\n' ;;
      *) json_payload ;;
    esac
    ;;
  "pr comment")
    exit 0
    ;;
  "pr merge")
    printf '%s\n' "$*" >> "${MERGE_LOG:?}"
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN/gh"

export PATH="$BIN:$PATH"
export MERGE_LOG="$TMPROOT/merge.log"
export HOME="$TMPROOT/home"
export ACHILLES_PROJECT="pr-merge-method"
EVENT_LOG="$HOME/.dev-studio/$ACHILLES_PROJECT/events/$(date -u +%Y-%m-%d).jsonl"

(
  cd "$WORK" || exit 1
  git init -q
  git checkout -b main -q
  git config user.email test@example.invalid
  git config user.name test
  printf 'x\n' > README.md
  git add README.md
  git commit -q -m init
)

failures=0
assert() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

run_case() {
  local base="$1" count="$2" expected="$3" out
  out="$TMPROOT/out-$base-$count.txt"
  : > "$MERGE_LOG"
  BASE_REF="$base" COMMIT_COUNT="$count" \
    bash "$ROOT/scripts/pr-merge-finalize.sh" 123 --method auto \
      --bypass-review --user-approved-bypass https://github.com/owner/repo/pull/123 \
      > "$out" 2>"$out.err"
  assert "auto $base $count commits reports $expected" "grep -q 'MERGE_METHOD=$expected' '$out'"
  assert "auto $base $count commits calls gh --$expected" "grep -q -- '--$expected' '$MERGE_LOG'"
  assert "auto $base $count commits exits zero" "grep -q 'PR_MERGED=1' '$out'"
  assert "auto $base $count commits emits merge-finalize duration" \
    "jq -e 'select(.event==\"pr_merge_finalize_completed\" and .data.duration_s >= 0 and .data.cleanup_failed == true)' '$EVENT_LOG' >/dev/null"
}

cd "$WORK" || exit 1
run_case main 3 rebase
run_case main 4 merge
run_case feature 4 rebase

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s)\n' "$failures" >&2
  exit 1
fi

printf 'PASS: PR merge method policy\n'
