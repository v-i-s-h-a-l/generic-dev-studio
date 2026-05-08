#!/usr/bin/env bash
# Verifies checkpoint resume discovers durable login-home checkpoints across
# project indexes when a host runs with a synthetic HOME.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t checkpoint-resume-discovery-750.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
LOGIN_HOME="$TMPROOT/login-home"
SYNTH_HOME="$TMPROOT/.codex-homes/personal"
REPO="$TMPROOT/repo"
mkdir -p "$BIN" "$LOGIN_HOME" "$SYNTH_HOME" "$REPO"

cat > "$BIN/dscl" <<SH
#!/usr/bin/env bash
printf 'NFSHomeDirectory: %s\n' "$LOGIN_HOME"
SH
chmod +x "$BIN/dscl"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Checkpoint Discovery Test"
printf 'one\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m init
git -C "$REPO" checkout -q -b feature/test

run_login_checkpoint() {
  local project="$1"
  shift
  (cd "$REPO" && PATH="$BIN:$PATH" HOME="$LOGIN_HOME" ACHILLES_PROJECT="$project" "$ROOT/scripts/studio-checkpoint.sh" "$@")
}

run_synthetic_checkpoint() {
  local project="$1"
  shift
  (cd "$REPO" && PATH="$BIN:$PATH" HOME="$SYNTH_HOME" ACHILLES_PROJECT="$project" "$ROOT/scripts/studio-checkpoint.sh" "$@")
}

run_login_checkpoint project-a create \
  --role worker \
  --goal "Login-home checkpoint" \
  --completed "Created from durable home" \
  --checkpoint-id ckpt-login-home >/dev/null

[ -d "$LOGIN_HOME/.dev-studio/project-a/.runtime/v2/checkpoints/sessions/ckpt-login-home" ] \
  || fail "checkpoint was not written under login-home durable state"
[ ! -d "$SYNTH_HOME/.dev-studio/project-a" ] \
  || fail "checkpoint leaked into synthetic host HOME"

login_home_resume=$(run_synthetic_checkpoint project-a resume --checkpoint-id ckpt-login-home --role worker)
printf '%s\n' "$login_home_resume" | grep -Fq 'Checkpoint: `ckpt-login-home`' \
  || fail "synthetic HOME resume did not find login-home checkpoint"

run_login_checkpoint project-b create \
  --role worker \
  --goal "Cross-project checkpoint" \
  --completed "Created in another project" \
  --checkpoint-id ckpt-cross-project >/dev/null

cross_err="$TMPROOT/cross.err"
cross_out=$(run_synthetic_checkpoint project-a resume --checkpoint-id ckpt-cross-project --role worker 2>"$cross_err")
printf '%s\n' "$cross_out" | grep -Fq 'Checkpoint: `ckpt-cross-project`' \
  || fail "cross-project checkpoint id was not resumed"
grep -Fq 'resolved project=project-b role=worker branch=feature/test' "$cross_err" \
  || fail "cross-project resolution did not report the project/role/branch candidate"

run_login_checkpoint project-c create \
  --role worker \
  --goal "Ambiguous checkpoint one" \
  --completed "First matching project" \
  --checkpoint-id ckpt-ambiguous >/dev/null
run_login_checkpoint project-d create \
  --role worker \
  --goal "Ambiguous checkpoint two" \
  --completed "Second matching project" \
  --checkpoint-id ckpt-ambiguous >/dev/null

if run_synthetic_checkpoint project-a resume --checkpoint-id ckpt-ambiguous --role worker >"$TMPROOT/ambiguous.out" 2>"$TMPROOT/ambiguous.err"; then
  fail "ambiguous checkpoint id unexpectedly resumed"
fi
grep -Fq 'checkpoint id matched multiple durable checkpoint candidates' "$TMPROOT/ambiguous.err" \
  || fail "ambiguous checkpoint failure was not explicit"
grep -Fq 'project=project-c role=worker branch=feature/test checkpoint_id=ckpt-ambiguous' "$TMPROOT/ambiguous.err" \
  || fail "ambiguous candidates did not include project-c"
grep -Fq 'project=project-d role=worker branch=feature/test checkpoint_id=ckpt-ambiguous' "$TMPROOT/ambiguous.err" \
  || fail "ambiguous candidates did not include project-d"

run_login_checkpoint project-b create \
  --role manager \
  --goal "Manager-only checkpoint" \
  --completed "Different role" \
  --checkpoint-id ckpt-manager-only >/dev/null

if run_synthetic_checkpoint project-a resume --checkpoint-id ckpt-manager-only --role worker >"$TMPROOT/role.out" 2>"$TMPROOT/role.err"; then
  fail "role-mismatched checkpoint unexpectedly resumed"
fi
grep -Fq 'checkpoint id was found, but not for requested role' "$TMPROOT/role.err" \
  || fail "role mismatch was not distinguished from not-found"
grep -Fq 'project=project-b role=manager branch=feature/test checkpoint_id=ckpt-manager-only' "$TMPROOT/role.err" \
  || fail "role mismatch did not list the manager candidate"

run_login_checkpoint project-b create \
  --role worker \
  --goal "Nearby checkpoint" \
  --completed "Near match for typo reports" \
  --checkpoint-id ckpt-near-alpha >/dev/null

if run_synthetic_checkpoint project-a resume --checkpoint-id ckpt-near --role worker >"$TMPROOT/missing.out" 2>"$TMPROOT/missing.err"; then
  fail "missing checkpoint id unexpectedly resumed"
fi
grep -Fq 'checkpoint id not found anywhere: ckpt-near' "$TMPROOT/missing.err" \
  || fail "missing checkpoint did not report not-found-anywhere"
grep -Fq "$LOGIN_HOME/.dev-studio/project-a/.runtime/v2/checkpoints" "$TMPROOT/missing.err" \
  || fail "missing checkpoint did not report the requested project root"
grep -Fq "$LOGIN_HOME/.dev-studio/project-b/.runtime/v2/checkpoints" "$TMPROOT/missing.err" \
  || fail "missing checkpoint did not report searched durable project roots"
grep -Fq 'project=project-b role=worker branch=feature/test checkpoint_id=ckpt-near-alpha' "$TMPROOT/missing.err" \
  || fail "missing checkpoint did not report nearby ids"

printf 'PASS: checkpoint resume host-safe cross-project discovery\n'
