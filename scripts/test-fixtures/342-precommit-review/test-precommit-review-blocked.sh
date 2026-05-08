#!/usr/bin/env bash
# Verifies a blocked staged-diff verdict rejects the commit gate.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t precommit-review-blocked.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
REPO="$TMPROOT/repo"
mkdir -p "$BIN" "$REPO"

cat > "$BIN/yq" <<'SH'
#!/usr/bin/env bash
expr="$2"
case "$expr" in
  *detect_binary*) printf 'codex\n' ;;
  *capabilities_path*) printf '.codex-reviewer/capabilities.yaml\n' ;;
  *) printf 'unexpected yq expression: %s\n' "$expr" >&2; exit 2 ;;
esac
SH
chmod +x "$BIN/yq"

cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) printf 'codex fixture help\n'; exit 0 ;;
esac
printf 'critical blocker\n'
printf 'STUDIO_REVIEW_VERDICT=blocked\n'
SH
chmod +x "$BIN/codex"

export PATH="$BIN:$PATH"
export HOME="$TMPROOT/caller-home"
export TMPDIR="$TMPROOT/session-tmp"
export STUDIO_CONTEXT_STUDIO_HOME="$TMPROOT/durable-home/.dev-studio"
export CODEX_HOME="$HOME/.codex"
mkdir -p "$CODEX_HOME" "$TMPDIR" "$(dirname "$STUDIO_CONTEXT_STUDIO_HOME")"

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
printf 'one\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm initial
printf 'two\n' >> "$REPO/file.txt"
git -C "$REPO" add file.txt

if (cd "$REPO" && bash "$ROOT/scripts/pre-commit-review.sh" --review-host codex-reviewer >"$TMPROOT/out" 2>"$TMPROOT/err"); then
  printf 'FAIL: blocked verdict was accepted\n' >&2
  exit 1
fi

grep -q 'reviewer blocked commit' "$TMPROOT/err" || {
  printf 'FAIL: blocked verdict did not explain rejection\n' >&2
  sed -n '1,80p' "$TMPROOT/err" >&2 || true
  exit 1
}

printf 'PASS: pre-commit review rejects blocked verdict\n'
