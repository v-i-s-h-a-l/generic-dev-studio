#!/usr/bin/env bash
# Fixture for scripts/lib-github-transport.sh (#874 / #876 / #878).
#
# Proves that the shared gh-backed Git transport helper:
#
#   1. Classifies credential.helper values: absolute path → stale when
#      missing/non-executable; `!shell-cmd` → fresh; PATH-resolvable
#      `cache` / `store` → fresh; bare unknown name → stale.
#   2. Emits `credential_helper_stale` for a configured-but-broken
#      credential.helper and still completes the underlying git call
#      (the helper overrides via `git -c credential.helper=!gh auth git-credential`).
#   3. Emits `gh_missing` (rc 127) when `gh` is not on PATH (default mode).
#   4. Emits `gh_auth_missing` (rc 1) when `gh auth status` fails
#      (default mode).
#   5. Emits `ssh_mode_explicit` and skips gh/auth checks under
#      `--ssh` or `STUDIO_GIT_TRANSPORT_FORCE_SSH=1`.
#   6. Anonymous mode does not require `gh`, but still reports stale
#      credential helpers.
#   7. Exposes `studio_git_transport_last_diagnostic` and
#      `studio_git_transport_last_error` accessors.
#
# Runs in-place against a synthetic HOME and a local bare repo used as
# the "remote" so no GitHub network or real credential helper is contacted.
# The bare repo proves the default-mode git transport actually completes
# end-to-end with the stale helper detection + override in place.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
HELPER="$ROOT/scripts/lib-github-transport.sh"

[ -f "$HELPER" ] || { printf 'FAIL: %s missing\n' "$HELPER" >&2; exit 1; }

TMP=$(mktemp -d -t lib-github-transport.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# -------------------------------------------------------------------
# Synthetic environment. A throwaway HOME under $TMP ensures the
# fixture's `git config --global` writes never reach the real user
# config; a stubbed PATH lets each case choose whether `gh` is
# present and how it behaves.
# -------------------------------------------------------------------
export HOME="$TMP/home"
mkdir -p "$HOME"
export STUDIO_BYPASS_PARENT_HOME_FLIP=1  # keep HOME stable for assertions
unset STUDIO_GIT_TRANSPORT_FORCE_SSH STUDIO_GIT_TRANSPORT_ANONYMOUS \
      STUDIO_GIT_TRANSPORT_LAST_ERROR STUDIO_GIT_TRANSPORT_LAST_DIAGNOSTIC

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

# Seed a deterministic git identity for the bare-repo init below.
git config --global --replace-all user.email "fixture@local"
git config --global --replace-all user.name  "fixture"

# Bare repo acts as the "remote" the helper points git at.
BARE="$TMP/bare.git"
git init -q --bare "$BARE"
# Seed it with one ref so ls-remote returns a non-empty result.
SEED="$TMP/seed"
git init -q "$SEED"
( cd "$SEED" \
    && git config user.email "fixture@local" \
    && git config user.name  "fixture" \
    && git commit -q --allow-empty -m "seed" \
    && git push -q "$BARE" HEAD:refs/heads/main )

# Helper to source lib-github-transport.sh into a subshell with a
# specific PATH. Always re-sources from scratch so each case starts
# with empty STUDIO_GIT_TRANSPORT_LAST_* state. /bin and /usr/bin are
# always prepended so shell builtins remain resolvable.
BASH_BIN=$(command -v bash)
run_in_helper() {
  local path="$1"; shift
  PATH="/usr/bin:/bin:$path" \
  HOME="$HOME" \
  STUDIO_BYPASS_PARENT_HOME_FLIP=1 \
  "$BASH_BIN" -c "
    set -eu
    unset STUDIO_GIT_TRANSPORT_LAST_ERROR STUDIO_GIT_TRANSPORT_LAST_DIAGNOSTIC
    . '$HELPER'
    $*
  "
}

PATH_WITH_REAL_GIT=$(dirname "$(command -v git)")

write_gh_stub_pass() {
  cat > "$STUB_BIN/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  auth)
    case "${2:-}" in
      status) exit 0 ;;
      git-credential)
        # `git -c credential.helper=!gh auth git-credential` invokes
        # this only when a credential is actually requested. The
        # fixture's bare-repo target never prompts, so reaching this
        # branch would itself be a bug.
        printf 'protocol=https\nusername=fixture\npassword=fixture\n'
        exit 0
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$STUB_BIN/gh"
}

write_gh_stub_fail_status() {
  cat > "$STUB_BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf 'gh: not authenticated\n' >&2
  exit 1
fi
exit 0
SH
  chmod +x "$STUB_BIN/gh"
}

# ---------------------------------------------------------------------
# Case 1 — classification of credential.helper values.
# ---------------------------------------------------------------------
# shellcheck disable=SC2016  # heredoc body expands inside run_in_helper subshell
case_out=$(run_in_helper "$PATH_WITH_REAL_GIT" '
  fail=0
  _sgt_helper_value_is_stale "/no/such/path/git-credential-foo" \
    && echo "stale: missing-abs-path: ok" \
    || { echo "FAIL stale: missing-abs-path"; fail=1; }
  _sgt_helper_value_is_stale "!gh auth git-credential" \
    && { echo "FAIL stale: shell-cmd"; fail=1; } \
    || echo "stale: shell-cmd: ok"
  _sgt_helper_value_is_stale "cache" \
    && { echo "FAIL stale: cache"; fail=1; } \
    || echo "stale: cache: ok"
  _sgt_helper_value_is_stale "store" \
    && { echo "FAIL stale: store"; fail=1; } \
    || echo "stale: store: ok"
  _sgt_helper_value_is_stale "definitely-not-a-real-helper" \
    && echo "stale: bare-unknown: ok" \
    || { echo "FAIL stale: bare-unknown"; fail=1; }
  exit "$fail"
')
if ! printf '%s\n' "$case_out" | grep -q "stale: missing-abs-path: ok"; then
  printf 'FAIL case 1 (classification): %s\n' "$case_out" >&2; exit 1
fi
if printf '%s\n' "$case_out" | grep -q "^FAIL "; then
  printf 'FAIL case 1 (classification): %s\n' "$case_out" >&2; exit 1
fi

# ---------------------------------------------------------------------
# Case 2 — stale-helper config triggers `credential_helper_stale`
# but the underlying git ls-remote still completes against the
# bare-repo target because the helper injects an override via `git -c`.
# ---------------------------------------------------------------------
git config --global credential.helper "/no/such/path/git-credential-broken"
write_gh_stub_pass

PATH_WITH_STUB="$STUB_BIN:$PATH_WITH_REAL_GIT"
case2_out=$(run_in_helper "$PATH_WITH_STUB" "
  studio_git_transport_ls_remote '$BARE' HEAD >/dev/null
  rc=\$?
  echo \"ls-remote rc=\$rc\"
  echo \"diagnostic=\$(studio_git_transport_last_diagnostic)\"
  exit \$rc
" 2>"$TMP/case2.err") || {
    printf 'FAIL case 2: ls-remote returned non-zero\n%s\n%s\n' \
      "$case2_out" "$(cat "$TMP/case2.err")" >&2
    exit 1
  }

grep -q 'credential_helper_stale' "$TMP/case2.err" \
  || { printf 'FAIL case 2: missing credential_helper_stale diagnostic\n%s\n' \
         "$(cat "$TMP/case2.err")" >&2; exit 1; }
grep -q 'diagnostic=credential_helper_stale' <<<"$case2_out" \
  || { printf 'FAIL case 2: STUDIO_GIT_TRANSPORT_LAST_DIAGNOSTIC not set\n%s\n' \
         "$case2_out" >&2; exit 1; }
grep -q 'ls-remote rc=0' <<<"$case2_out" \
  || { printf 'FAIL case 2: helper did not complete ls-remote rc=0\n%s\n' \
         "$case2_out" >&2; exit 1; }

git config --global --unset-all credential.helper || true

# ---------------------------------------------------------------------
# Case 3 — `gh` not on PATH → `gh_missing` diagnostic, rc 127.
# ---------------------------------------------------------------------
PATH_NO_GH="$PATH_WITH_REAL_GIT"
set +e
case3_err=$(run_in_helper "$PATH_NO_GH" "
  studio_git_transport_ls_remote '$BARE' HEAD >/dev/null
  rc=\$?
  printf 'rc=%s diagnostic=%s\n' \"\$rc\" \"\$(studio_git_transport_last_diagnostic)\"
  exit \$rc
" 2>&1)
rc=$?
set -e
[ "$rc" = "127" ] \
  || { printf 'FAIL case 3: expected rc=127 got rc=%s\n%s\n' "$rc" "$case3_err" >&2; exit 1; }
grep -q 'gh_missing' <<<"$case3_err" \
  || { printf 'FAIL case 3: gh_missing diagnostic not emitted\n%s\n' "$case3_err" >&2; exit 1; }

# ---------------------------------------------------------------------
# Case 4 — `gh auth status` fails → `gh_auth_missing` diagnostic, rc 1.
# ---------------------------------------------------------------------
write_gh_stub_fail_status
set +e
case4_err=$(run_in_helper "$STUB_BIN:$PATH_WITH_REAL_GIT" "
  studio_git_transport_ls_remote '$BARE' HEAD >/dev/null
  rc=\$?
  printf 'rc=%s diagnostic=%s\n' \"\$rc\" \"\$(studio_git_transport_last_diagnostic)\"
  exit \$rc
" 2>&1)
rc=$?
set -e
[ "$rc" = "1" ] \
  || { printf 'FAIL case 4: expected rc=1 got rc=%s\n%s\n' "$rc" "$case4_err" >&2; exit 1; }
grep -q 'gh_auth_missing' <<<"$case4_err" \
  || { printf 'FAIL case 4: gh_auth_missing diagnostic not emitted\n%s\n' "$case4_err" >&2; exit 1; }

# ---------------------------------------------------------------------
# Case 5 — `--ssh` mode emits `ssh_mode_explicit` and skips gh checks
# entirely (no `gh` on PATH, but the call still succeeds).
# ---------------------------------------------------------------------
case5_err=$(run_in_helper "$PATH_WITH_REAL_GIT" "
  studio_git_transport_run ls-remote --ssh -- ls-remote '$BARE' HEAD >/dev/null
  rc=\$?
  printf 'rc=%s diagnostic=%s\n' \"\$rc\" \"\$(studio_git_transport_last_diagnostic)\"
  exit \$rc
" 2>&1) || {
    printf 'FAIL case 5 (--ssh): %s\n' "$case5_err" >&2; exit 1;
  }
grep -q 'ssh_mode_explicit' <<<"$case5_err" \
  || { printf 'FAIL case 5: ssh_mode_explicit diagnostic not emitted\n%s\n' "$case5_err" >&2; exit 1; }
grep -q 'gh_missing' <<<"$case5_err" \
  && { printf 'FAIL case 5: gh_missing fired in ssh mode\n%s\n' "$case5_err" >&2; exit 1; }

# Same expectation under `STUDIO_GIT_TRANSPORT_FORCE_SSH=1`, even when
# the call site asks for `--default`.
case5b_err=$(STUDIO_GIT_TRANSPORT_FORCE_SSH=1 run_in_helper "$PATH_WITH_REAL_GIT" "
  studio_git_transport_run ls-remote --default -- ls-remote '$BARE' HEAD >/dev/null
  rc=\$?
  printf 'rc=%s diagnostic=%s\n' \"\$rc\" \"\$(studio_git_transport_last_diagnostic)\"
  exit \$rc
" 2>&1) || {
    printf 'FAIL case 5b (force-ssh env): %s\n' "$case5b_err" >&2; exit 1;
  }
grep -q 'ssh_mode_explicit' <<<"$case5b_err" \
  || { printf 'FAIL case 5b: STUDIO_GIT_TRANSPORT_FORCE_SSH did not coerce ssh mode\n%s\n' \
         "$case5b_err" >&2; exit 1; }

# ---------------------------------------------------------------------
# Case 6 — anonymous mode: no gh required, stale-helper detection
# still runs, transport completes against the bare repo.
# ---------------------------------------------------------------------
git config --global credential.helper "/no/such/path/git-credential-anon"
case6_out=$(run_in_helper "$PATH_WITH_REAL_GIT" "
  studio_git_transport_run ls-remote --anonymous -- ls-remote '$BARE' HEAD >/dev/null
  rc=\$?
  printf 'rc=%s diagnostic=%s\n' \"\$rc\" \"\$(studio_git_transport_last_diagnostic)\"
  exit \$rc
" 2>"$TMP/case6.err") || {
    printf 'FAIL case 6 (anonymous): %s\n%s\n' "$case6_out" "$(cat "$TMP/case6.err")" >&2
    exit 1
  }
grep -q 'credential_helper_stale' "$TMP/case6.err" \
  || { printf 'FAIL case 6: stale-helper diagnostic not emitted in anonymous mode\n%s\n' \
         "$(cat "$TMP/case6.err")" >&2; exit 1; }
grep -q 'rc=0' <<<"$case6_out" \
  || { printf 'FAIL case 6: anonymous ls-remote did not return rc=0\n%s\n' "$case6_out" >&2; exit 1; }
git config --global --unset-all credential.helper || true

# ---------------------------------------------------------------------
# Case 7 — last_error / last_diagnostic accessors expose the last
# emitted values to callers that want to classify failure programmatically.
# ---------------------------------------------------------------------
# shellcheck disable=SC2016  # heredoc body expands inside run_in_helper subshell
case7_out=$(run_in_helper "$PATH_WITH_REAL_GIT" '
  studio_git_transport_run "" -- ls-remote "/dev/null" >/dev/null 2>&1 || true
  printf "diagnostic=%s\n" "$(studio_git_transport_last_diagnostic)"
  printf "error=%s\n"      "$(studio_git_transport_last_error)"
')
grep -q 'diagnostic=usage' <<<"$case7_out" \
  || { printf 'FAIL case 7: empty op did not set usage diagnostic\n%s\n' "$case7_out" >&2; exit 1; }
grep -q 'error=' <<<"$case7_out" \
  || { printf 'FAIL case 7: last_error accessor empty\n%s\n' "$case7_out" >&2; exit 1; }

printf 'PASS: lib-github-transport fixture (stale-helper classification, credential_helper_stale + override, gh_missing, gh_auth_missing, ssh_mode_explicit, anonymous-mode stale detection, last-diagnostic accessors)\n'
