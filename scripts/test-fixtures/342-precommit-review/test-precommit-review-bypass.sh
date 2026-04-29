#!/usr/bin/env bash
# Verifies explicit user bypass skips the reviewer and emits an audit event.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t precommit-review-bypass.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
REPO="$TMPROOT/repo"
mkdir -p "$BIN" "$REPO"

cat > "$BIN/yq" <<'SH'
#!/usr/bin/env bash
printf 'yq should not be called during bypass\n' >&2
exit 9
SH
chmod +x "$BIN/yq"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
printf 'codex should not be called during bypass\n' >&2
exit 8
SH
chmod +x "$BIN/codex"

export PATH="$BIN:$PATH"
export HOME="$TMPROOT/caller-home"
export STUDIO_BYPASS_REVIEW=1
mkdir -p "$HOME/.codex"

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
printf 'one\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm initial
printf 'two\n' >> "$REPO/file.txt"
git -C "$REPO" add file.txt

if ! (cd "$REPO" && bash "$ROOT/scripts/pre-commit-review.sh" >"$TMPROOT/out" 2>"$TMPROOT/err"); then
  printf 'FAIL: explicit bypass failed\n' >&2
  sed -n '1,80p' "$TMPROOT/err" >&2 || true
  exit 1
fi

grep -q 'STUDIO REVIEW GATE BYPASSED' "$TMPROOT/err" || {
  printf 'FAIL: bypass was not loud\n' >&2
  exit 1
}
if ! find "$HOME/.dev-studio" -type f -name '*.jsonl' -print0 2>/dev/null \
    | xargs -0 grep -q 'precommit_review_bypassed'; then
  printf 'FAIL: bypass audit event not emitted\n' >&2
  find "$HOME/.dev-studio" -type f -maxdepth 5 -print 2>/dev/null >&2 || true
  exit 1
fi

printf 'PASS: pre-commit review bypass is loud and audited\n'
