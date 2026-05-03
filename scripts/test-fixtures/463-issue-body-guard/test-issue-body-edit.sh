#!/usr/bin/env bash

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t issue-body-edit-test.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -u

log="${GH_STUB_LOG:?}"
printf '%s\n' "$*" >> "$log"

case "$1 $2" in
  "issue view")
    printf '%s\n' '{"number":463,"title":"Fixture issue","url":"https://github.com/owner/repo/issues/463","body":"existing line one\nexisting line two\n"}'
    ;;
  "issue edit")
    body_file=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --body-file) body_file="${2:?}"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$body_file" ] || { printf 'missing --body-file\n' >&2; exit 3; }
    cp "$body_file" "${GH_STUB_EDITED_BODY:?}"
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN/gh"

export PATH="$BIN:$PATH"
export GH_STUB_LOG="$TMPROOT/gh.log"
export GH_STUB_EDITED_BODY="$TMPROOT/edited-body.md"
export HOME="$TMPROOT/home"
mkdir -p "$HOME"

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

short_body="$TMPROOT/short.md"
valid_body="$TMPROOT/valid.md"
printf 'tiny\n' > "$short_body"
cat > "$valid_body" <<'EOF'
Generated issue body replacement.
This has enough content to pass the default byte threshold.
This third line satisfies the default line threshold.
EOF

: > "$GH_STUB_LOG"
if bash "$ROOT/scripts/issue-body-edit.sh" 463 --repo owner/repo < /dev/null >"$TMPROOT/empty.out" 2>"$TMPROOT/empty.err"; then
  empty_rc=0
else
  empty_rc=$?
fi
assert "empty input rejected" "[ '$empty_rc' -ne 0 ] && grep -q 'empty body' '$TMPROOT/empty.err'"
assert "empty rejection does not call gh" "[ ! -s '$GH_STUB_LOG' ]"

: > "$GH_STUB_LOG"
if bash "$ROOT/scripts/issue-body-edit.sh" 463 --repo owner/repo --body-file "$short_body" >"$TMPROOT/short.out" 2>"$TMPROOT/short.err"; then
  short_rc=0
else
  short_rc=$?
fi
assert "short input rejected" "[ '$short_rc' -ne 0 ] && grep -q 'refusing short generated body' '$TMPROOT/short.err'"
assert "short rejection does not call gh" "[ ! -s '$GH_STUB_LOG' ]"

: > "$GH_STUB_LOG"
bash "$ROOT/scripts/issue-body-edit.sh" 463 --repo owner/repo --body-file "$valid_body" >"$TMPROOT/dry.out" 2>"$TMPROOT/dry.err"
dry_rc=$?
assert "valid dry-run exits zero" "[ '$dry_rc' -eq 0 ]"
assert "dry-run prints preview" "grep -q 'old body' '$TMPROOT/dry.err' && grep -q 'new body' '$TMPROOT/dry.err'"
assert "dry-run does not edit" "! grep -q '^issue edit' '$GH_STUB_LOG'"

: > "$GH_STUB_LOG"
rm -f "$GH_STUB_EDITED_BODY"
bash "$ROOT/scripts/issue-body-edit.sh" 463 --repo owner/repo --body-file "$valid_body" --apply >"$TMPROOT/apply.out" 2>"$TMPROOT/apply.err"
apply_rc=$?
assert "valid apply exits zero" "[ '$apply_rc' -eq 0 ]"
assert "valid apply calls gh issue edit" "grep -q '^issue edit 463 --repo owner/repo --body-file ' '$GH_STUB_LOG'"
assert "valid apply sends generated body" "cmp -s '$valid_body' '$GH_STUB_EDITED_BODY'"

: > "$GH_STUB_LOG"
rm -f "$GH_STUB_EDITED_BODY"
STUDIO_BYPASS_ISSUE_BODY_GUARD=1 bash "$ROOT/scripts/issue-body-edit.sh" 463 --repo owner/repo --body-file "$short_body" --apply >"$TMPROOT/bypass.out" 2>"$TMPROOT/bypass.err"
bypass_rc=$?
assert "user bypass permits short apply" "[ '$bypass_rc' -eq 0 ] && cmp -s '$short_body' '$GH_STUB_EDITED_BODY'"
assert "user bypass is loud" "grep -q 'STUDIO_BYPASS_ISSUE_BODY_GUARD active' '$TMPROOT/bypass.err'"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s)\n' "$failures" >&2
  exit 1
fi

printf 'PASS: issue body edit guard\n'
