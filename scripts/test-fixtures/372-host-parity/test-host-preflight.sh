#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t host-preflight-372.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
REPO="$TMPROOT/repo"
REAL_GIT=$(command -v git)
mkdir -p "$BIN" "$HOME_DIR" "$REPO"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "auth status")
    case "${GH_AUTH_STATUS:-ok}" in
      ok) exit 0 ;;
      *) printf 'not logged in\n' >&2; exit 1 ;;
    esac
    ;;
esac
printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 2
SH

cat > "$BIN/git" <<SH
#!/usr/bin/env bash
if [ "\$1" = "-C" ] && [ "\$3" = "ls-remote" ]; then
  printf 'ls-remote\\n' >> "$TMPROOT/git-calls"
  case "\${LS_REMOTE_STATUS:-ok}" in
    ok) exit 0 ;;
    *) printf 'auth failed\\n' >&2; exit 128 ;;
  esac
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$BIN/gh" "$BIN/git"

(
  cd "$REPO"
  "$REAL_GIT" init -q
  "$REAL_GIT" config user.email test@example.invalid
  "$REAL_GIT" config user.name Test
  "$REAL_GIT" remote add origin https://github.com/example/private.git
  printf 'seed\n' > README.md
  "$REAL_GIT" add README.md
  "$REAL_GIT" commit -qm initial
)

set +e
PATH="$BIN:$PATH" HOME="$HOME_DIR" GH_AUTH_STATUS=fail \
  "$ROOT/scripts/host-preflight.sh" codex "$REPO" >"$TMPROOT/gh.out" 2>"$TMPROOT/gh.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || { printf 'FAIL: gh auth failure passed\n' >&2; exit 1; }
[ ! -f "$TMPROOT/git-calls" ] || { printf 'FAIL: ls-remote ran after gh auth failure\n' >&2; exit 1; }
grep -q 'gh auth status' "$TMPROOT/gh.err" || { printf 'FAIL: missing gh auth diagnostic\n' >&2; cat "$TMPROOT/gh.err" >&2; exit 1; }

PATH="$BIN:$PATH" HOME="$HOME_DIR" GH_AUTH_STATUS=ok LS_REMOTE_STATUS=ok \
  "$ROOT/scripts/host-preflight.sh" codex "$REPO" >"$TMPROOT/pass.out" 2>"$TMPROOT/pass.err"
grep -q 'ls-remote' "$TMPROOT/git-calls" || { printf 'FAIL: git ls-remote was not exercised\n' >&2; exit 1; }
grep -q 'PASS host=codex' "$TMPROOT/pass.err" || { printf 'FAIL: missing pass diagnostic\n' >&2; cat "$TMPROOT/pass.err" >&2; exit 1; }

if ! grep -q 'host_preflight "$host" "$REPO_ROOT"' "$ROOT/scripts/studio-chain-runner.sh"; then
  printf 'FAIL: studio-chain-runner does not call host preflight before chain work\n' >&2
  exit 1
fi

if ! grep -q 'HOME="$launch_home" "$SCRIPT_DIR/host-preflight.sh"' "$ROOT/scripts/studio-chain-runner.sh"; then
  printf 'FAIL: studio-chain-runner preflight does not use the worker launch HOME\n' >&2
  exit 1
fi

if ! grep -q 'launch_home=$(host_launch_home)' "$ROOT/scripts/studio-chain-runner.sh"; then
  printf 'FAIL: worker spawn and preflight do not share host launch HOME resolution\n' >&2
  exit 1
fi

printf 'PASS: host preflight verifies gh and git credential access\n'
