#!/usr/bin/env bash
# Verifies parent-side GitHub calls use the login HOME from synthetic Codex homes.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t parent-home-host.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
LOGIN_HOME="$TMPROOT/login-home"
SYNTH_HOME="$TMPROOT/.codex-homes/personal"
mkdir -p "$BIN" "$LOGIN_HOME" "$SYNTH_HOME"

cat > "$BIN/dscl" <<SH
#!/usr/bin/env bash
printf 'NFSHomeDirectory: %s\n' "$LOGIN_HOME"
SH
chmod +x "$BIN/dscl"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$HOME" >> "${GH_HOME_LOG:?}"
case "$1 $2" in
  "auth status") exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/gh"

GH_HOME_LOG="$TMPROOT/gh-home.log"
export GH_HOME_LOG

out="$TMPROOT/out"
err="$TMPROOT/err"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" bash -c "
  . '$ROOT/scripts/lib-paths.sh'
  resolve_current_studio_host
  with_login_home_for_github gh auth status
" >"$out" 2>"$err"

grep -qx 'codex' "$out"
grep -qx "$LOGIN_HOME" "$GH_HOME_LOG"
grep -q 'studio: HOME normalized for GitHub op (parent=codex)' "$err"

: > "$GH_HOME_LOG"
PATH="$BIN:$PATH" HOME="$SYNTH_HOME" STUDIO_BYPASS_PARENT_HOME_FLIP=1 bash -c "
  . '$ROOT/scripts/lib-paths.sh'
  with_login_home_for_github gh auth status
" >"$TMPROOT/bypass.out" 2>"$TMPROOT/bypass.err"

grep -qx "$SYNTH_HOME" "$GH_HOME_LOG"
if grep -q 'HOME normalized' "$TMPROOT/bypass.err"; then
  printf 'bypass still emitted HOME normalization log\n' >&2
  exit 1
fi

if command -v zsh >/dev/null 2>&1; then
  PATH="$BIN:$PATH" HOME="$SYNTH_HOME" zsh -c ". '$ROOT/scripts/lib-paths.sh'; resolve_current_studio_host" >"$TMPROOT/zsh.out"
  grep -qx 'codex' "$TMPROOT/zsh.out"
fi

printf 'PASS: parent HOME normalization and host inference\n'
