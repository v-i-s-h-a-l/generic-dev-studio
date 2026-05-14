#!/usr/bin/env bash
# Verify per-project Project board discovery in scripts/lib-studio-context.sh,
# scripts/lib-paths.sh, and scripts/studio-project-state.sh.
#
# Covers the discovery order from PM-SURFACE.md §Per-Project Project Board
# Portability Contract and _shared/contracts/studio-context.md §Project Board
# Resolution:
#   1. --project-board CLI flag wins.
#   2. STUDIO_PROJECT_BOARD_OVERRIDE env beats yaml files.
#   3. Runtime override file beats durable repo file.
#   4. Durable repo file used when nothing else is set.
#   5. Loud failure when no source supplies a board (non-studio project_slug).
#   6. Transitional studio default fires only for generic-dev-studio.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-project-board-test.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -u

log="${GH_STUB_LOG:?}"
printf '%s\n' "$*" >> "$log"

case "$1 $2" in
  "project item-list")
    printf '%s\n' '{ "items": [], "totalCount": 0 }'
    ;;
  "issue list")
    printf '%s\n' '[]'
    ;;
  "api graphql")
    printf '%s\n' '{}'
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN/gh"

export PATH="$BIN:$PATH"

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

# Helper: run studio-project-state.sh under a freshly scrubbed env so prior
# STUDIO_PROJECT_BOARD_* / STUDIO_PROJECT_OWNER / STUDIO_PROJECT_NUMBER vars
# from the developer's shell don't leak into the test.
run_state_script() {
  env -i \
    PATH="$PATH" \
    HOME="$1" \
    GH_STUB_LOG="$GH_STUB_LOG" \
    ACHILLES_PROJECT="$2" \
    "${@:3}" \
    bash "$ROOT/scripts/studio-project-state.sh" --json
}

###############################################################################
# Case 1 — durable repo file is read when nothing else is configured.
###############################################################################
case1_home="$TMPROOT/case1/home"
case1_repo="$TMPROOT/case1/repo"
mkdir -p "$case1_home" "$case1_repo/profiles/sample-app"
cat > "$case1_repo/profiles/sample-app/project-board.yaml" <<YAML
schema_version: 1
owner_kind: org
owner_login: Sample-Org
project_number: 7
project_title: Sample App roadmap
linked_repo: Sample-Org/sample-app
tracks:
  - Feature
  - Reliability
phases:
  - P1
  - P2
YAML

export GH_STUB_LOG="$TMPROOT/gh-case1.log"
: > "$GH_STUB_LOG"
env -i \
  PATH="$PATH" \
  HOME="$case1_home" \
  GH_STUB_LOG="$GH_STUB_LOG" \
  ACHILLES_PROJECT="sample-app" \
  STUDIO_CONTEXT_REPO_ROOT="$case1_repo" \
  STUDIO_PROJECT_REPO="Sample-Org/sample-app" \
  bash "$ROOT/scripts/studio-project-state.sh" --json \
  >"$TMPROOT/case1.out" 2>"$TMPROOT/case1.err"
case1_rc=$?
assert "case1 durable yaml exits zero" "[ '$case1_rc' -eq 0 ]"
assert "case1 durable yaml selects Sample-Org/7" \
  "grep -q '^project item-list 7 --owner Sample-Org' '$GH_STUB_LOG'"

###############################################################################
# Case 2 — runtime override wins over durable file.
###############################################################################
case2_home="$TMPROOT/case2/home"
case2_repo="$TMPROOT/case2/repo"
mkdir -p "$case2_home/.dev-studio/sample-app/config" "$case2_repo/profiles/sample-app"
cat > "$case2_repo/profiles/sample-app/project-board.yaml" <<YAML
schema_version: 1
owner_kind: org
owner_login: Sample-Org
project_number: 7
project_title: Should be overridden
linked_repo: Sample-Org/sample-app
tracks: [Feature]
phases: [P1]
YAML
cat > "$case2_home/.dev-studio/sample-app/config/project-board.yaml" <<YAML
schema_version: 1
owner_kind: user
owner_login: experiments-user
project_number: 42
project_title: Local experiment board
linked_repo: experiments-user/sandbox
tracks: [Sandbox]
phases: [S1]
YAML

export GH_STUB_LOG="$TMPROOT/gh-case2.log"
: > "$GH_STUB_LOG"
env -i \
  PATH="$PATH" \
  HOME="$case2_home" \
  GH_STUB_LOG="$GH_STUB_LOG" \
  ACHILLES_PROJECT="sample-app" \
  STUDIO_CONTEXT_REPO_ROOT="$case2_repo" \
  STUDIO_PROJECT_REPO="Sample-Org/sample-app" \
  bash "$ROOT/scripts/studio-project-state.sh" --json \
  >"$TMPROOT/case2.out" 2>"$TMPROOT/case2.err"
case2_rc=$?
assert "case2 runtime override exits zero" "[ '$case2_rc' -eq 0 ]"
assert "case2 runtime override beats durable" \
  "grep -q '^project item-list 42 --owner experiments-user' '$GH_STUB_LOG'"
assert "case2 surfaces runtime override notice on stderr" \
  "grep -q 'project_board sourced from runtime override' '$TMPROOT/case2.err'"

###############################################################################
# Case 3 — STUDIO_PROJECT_BOARD_OVERRIDE env beats yaml files.
###############################################################################
export GH_STUB_LOG="$TMPROOT/gh-case3.log"
: > "$GH_STUB_LOG"
env -i \
  PATH="$PATH" \
  HOME="$case2_home" \
  GH_STUB_LOG="$GH_STUB_LOG" \
  ACHILLES_PROJECT="sample-app" \
  STUDIO_CONTEXT_REPO_ROOT="$case2_repo" \
  STUDIO_PROJECT_REPO="Sample-Org/sample-app" \
  STUDIO_PROJECT_BOARD_OVERRIDE="user:env-user:9" \
  bash "$ROOT/scripts/studio-project-state.sh" --json \
  >"$TMPROOT/case3.out" 2>"$TMPROOT/case3.err"
case3_rc=$?
assert "case3 env override exits zero" "[ '$case3_rc' -eq 0 ]"
assert "case3 env override beats runtime and durable yaml" \
  "grep -q '^project item-list 9 --owner env-user' '$GH_STUB_LOG'"

###############################################################################
# Case 4 — --project-board CLI flag wins over everything.
###############################################################################
export GH_STUB_LOG="$TMPROOT/gh-case4.log"
: > "$GH_STUB_LOG"
env -i \
  PATH="$PATH" \
  HOME="$case2_home" \
  GH_STUB_LOG="$GH_STUB_LOG" \
  ACHILLES_PROJECT="sample-app" \
  STUDIO_CONTEXT_REPO_ROOT="$case2_repo" \
  STUDIO_PROJECT_REPO="Sample-Org/sample-app" \
  STUDIO_PROJECT_BOARD_OVERRIDE="user:env-user:9" \
  bash "$ROOT/scripts/studio-project-state.sh" --json \
    --project-board "org:cli-org:99" \
  >"$TMPROOT/case4.out" 2>"$TMPROOT/case4.err"
case4_rc=$?
assert "case4 CLI flag exits zero" "[ '$case4_rc' -eq 0 ]"
assert "case4 CLI flag beats env and yaml" \
  "grep -q '^project item-list 99 --owner cli-org' '$GH_STUB_LOG'"

###############################################################################
# Case 5 — loud failure when no source supplies a board for a non-studio slug.
###############################################################################
case5_home="$TMPROOT/case5/home"
case5_repo="$TMPROOT/case5/repo"
mkdir -p "$case5_home" "$case5_repo"

export GH_STUB_LOG="$TMPROOT/gh-case5.log"
: > "$GH_STUB_LOG"
env -i \
  PATH="$PATH" \
  HOME="$case5_home" \
  GH_STUB_LOG="$GH_STUB_LOG" \
  ACHILLES_PROJECT="sample-app" \
  STUDIO_CONTEXT_REPO_ROOT="$case5_repo" \
  STUDIO_PROJECT_REPO="Sample-Org/sample-app" \
  bash "$ROOT/scripts/studio-project-state.sh" --json \
  >"$TMPROOT/case5.out" 2>"$TMPROOT/case5.err"
case5_rc=$?
assert "case5 loud-fails without config (non-studio slug)" "[ '$case5_rc' -ne 0 ]"
assert "case5 names project_slug in error" \
  "grep -q 'project_slug=sample-app' '$TMPROOT/case5.err'"
assert "case5 names expected durable path in error" \
  "grep -q 'profiles/sample-app/project-board.yaml' '$TMPROOT/case5.err'"
assert "case5 does not silently fall back to studio board" \
  "! grep -q '^project item-list' '$GH_STUB_LOG'"

###############################################################################
# Case 6 — transitional studio default fires only for generic-dev-studio.
###############################################################################
case6_home="$TMPROOT/case6/home"
case6_repo="$TMPROOT/case6/repo"
mkdir -p "$case6_home" "$case6_repo"

export GH_STUB_LOG="$TMPROOT/gh-case6.log"
: > "$GH_STUB_LOG"
env -i \
  PATH="$PATH" \
  HOME="$case6_home" \
  GH_STUB_LOG="$GH_STUB_LOG" \
  ACHILLES_PROJECT="generic-dev-studio" \
  STUDIO_CONTEXT_REPO_ROOT="$case6_repo" \
  STUDIO_PROJECT_REPO="v-i-s-h-a-l/generic-dev-studio" \
  bash "$ROOT/scripts/studio-project-state.sh" --json \
  >"$TMPROOT/case6.out" 2>"$TMPROOT/case6.err"
case6_rc=$?
assert "case6 studio fallback exits zero" "[ '$case6_rc' -eq 0 ]"
assert "case6 studio fallback uses legacy default" \
  "grep -q '^project item-list 1 --owner v-i-s-h-a-l' '$GH_STUB_LOG'"
assert "case6 surfaces transitional-default notice" \
  "grep -q 'transitional default user:v-i-s-h-a-l:1' '$TMPROOT/case6.err'"

###############################################################################
# Case 7 — legacy STUDIO_PROJECT_OWNER / STUDIO_PROJECT_NUMBER still work.
###############################################################################
export GH_STUB_LOG="$TMPROOT/gh-case7.log"
: > "$GH_STUB_LOG"
env -i \
  PATH="$PATH" \
  HOME="$case5_home" \
  GH_STUB_LOG="$GH_STUB_LOG" \
  ACHILLES_PROJECT="sample-app" \
  STUDIO_CONTEXT_REPO_ROOT="$case5_repo" \
  STUDIO_PROJECT_REPO="Sample-Org/sample-app" \
  STUDIO_PROJECT_OWNER="legacy-owner" \
  STUDIO_PROJECT_NUMBER="3" \
  bash "$ROOT/scripts/studio-project-state.sh" --json \
  >"$TMPROOT/case7.out" 2>"$TMPROOT/case7.err"
case7_rc=$?
assert "case7 legacy env exits zero" "[ '$case7_rc' -eq 0 ]"
assert "case7 legacy env synthesizes board token" \
  "grep -q '^project item-list 3 --owner legacy-owner' '$GH_STUB_LOG'"

###############################################################################
# Case 8 — invalid override token (bad owner_kind) loud-fails.
###############################################################################
export GH_STUB_LOG="$TMPROOT/gh-case8.log"
: > "$GH_STUB_LOG"
env -i \
  PATH="$PATH" \
  HOME="$case5_home" \
  GH_STUB_LOG="$GH_STUB_LOG" \
  ACHILLES_PROJECT="sample-app" \
  STUDIO_CONTEXT_REPO_ROOT="$case5_repo" \
  STUDIO_PROJECT_BOARD_OVERRIDE="enterprise:owner:5" \
  bash "$ROOT/scripts/studio-project-state.sh" --json \
  >"$TMPROOT/case8.out" 2>"$TMPROOT/case8.err"
case8_rc=$?
assert "case8 invalid owner_kind rejected" "[ '$case8_rc' -ne 0 ]"
assert "case8 error names the rejected token" \
  "grep -q 'owner_kind' '$TMPROOT/case8.err'"

###############################################################################
# Case 9 — lib helpers expose project_board fields through the envelope.
###############################################################################
case9_home="$TMPROOT/case9/home"
case9_repo="$TMPROOT/case9/repo"
mkdir -p "$case9_home" "$case9_repo/profiles/sample-project"
cat > "$case9_repo/profiles/sample-project/project-board.yaml" <<YAML
schema_version: 1
owner_kind: org
owner_login: SampleOrg
project_number: 11
project_title: Sample
linked_repo: SampleOrg/sample-project
tracks: [Demo]
phases: [Demo1]
YAML

env_dump=$(
  env -i \
    PATH="$PATH" \
    HOME="$case9_home" \
    ACHILLES_PROJECT="sample-project" \
    STUDIO_CONTEXT_REPO_ROOT="$case9_repo" \
    bash -c '
      set -u
      . "'"$ROOT"'/scripts/lib-studio-context.sh"
      studio_context_resolve pm-surface >/dev/null
      printf "PROJECT_BOARD=%s\n" "$STUDIO_CONTEXT_PROJECT_BOARD"
      printf "PROJECT_BOARD_SOURCE=%s\n" "$STUDIO_CONTEXT_PROJECT_BOARD_SOURCE"
    '
)
assert "case9 envelope carries project_board token" \
  "printf '%s' \"$env_dump\" | grep -q 'PROJECT_BOARD=org:SampleOrg:11'"
assert "case9 envelope tracks discovery source" \
  "printf '%s' \"$env_dump\" | grep -q 'PROJECT_BOARD_SOURCE=durable'"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s)\n' "$failures" >&2
  exit 1
fi

printf 'PASS: per-project Project board portability\n'
