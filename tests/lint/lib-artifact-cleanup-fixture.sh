#!/usr/bin/env bash
# lib-artifact-cleanup-fixture.sh — behavioral fixture for
# scripts/lib-artifact-cleanup.sh. Exits non-zero on any miss.
#
# Scenarios:
#   (a) clean on success exit
#   (b) clean on failure (non-zero exit)
#   (c) --keep-on-handoff transfers ownership without deletion
#   (d) STUDIO_KEEP_ARTIFACTS=1 retains everything + emits stderr audit
#
# Each scenario runs in its own subshell with HOME pointed at a unique
# tmpdir and ACHILLES_PROJECT pinned to a synthetic slug, so the
# resolver layer never touches the user's real durable-state root.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
LIB="$REPO_ROOT/scripts/lib-artifact-cleanup.sh"

if [ ! -f "$LIB" ]; then
  printf 'fixture: missing %s\n' "$LIB" >&2
  exit 2
fi

FAIL=0
fail() { printf 'FAIL[%s]: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }
pass() { printf 'pass[%s]: %s\n' "$1" "$2"; }

# Build a sandboxed HOME for one scenario. Returns the path on stdout.
make_sandbox() {
  local d
  d=$(mktemp -d -t lac-fixture-XXXXXX)
  printf '%s\n' "$d"
}

# Scenario (a): clean on success exit
run_a() {
  local home; home=$(make_sandbox)
  local artifact="$home/scratch-a"
  mkdir -p "$artifact"
  (
    export HOME="$home"
    export ACHILLES_PROJECT="lac-fixture"
    # shellcheck source=/dev/null
    . "$LIB"
    register_artifact tmpdir "$artifact"
    exit 0
  )
  if [ -e "$artifact" ]; then
    fail a "artifact still present after success exit: $artifact"
  else
    pass a "artifact removed on success exit"
  fi
  rm -rf "$home"
}

# Scenario (b): clean on failure (non-zero exit)
run_b() {
  local home; home=$(make_sandbox)
  local artifact="$home/scratch-b"
  mkdir -p "$artifact"
  (
    export HOME="$home"
    export ACHILLES_PROJECT="lac-fixture"
    # shellcheck source=/dev/null
    . "$LIB"
    register_artifact tmpdir "$artifact"
    exit 17
  )
  local rc=$?
  if [ "$rc" -ne 17 ]; then
    fail b "exit code not propagated (got $rc, want 17)"
  fi
  if [ -e "$artifact" ]; then
    fail b "artifact still present after failure exit: $artifact"
  else
    pass b "artifact removed on failure exit"
  fi
  rm -rf "$home"
}

# Scenario (c): --keep-on-handoff transfers ownership without deletion
run_c() {
  local home; home=$(make_sandbox)
  local artifact="$home/scratch-c"
  mkdir -p "$artifact"
  (
    export HOME="$home"
    export ACHILLES_PROJECT="lac-fixture"
    # shellcheck source=/dev/null
    . "$LIB"
    register_artifact xcresult "$artifact" --keep-on-handoff
    exit 0
  )
  if [ ! -e "$artifact" ]; then
    fail c "artifact deleted despite --keep-on-handoff: $artifact"
  fi
  local handoff_dir="$home/.dev-studio/lac-fixture/.runtime/state/artifact-cleanup/handoff"
  if [ ! -d "$handoff_dir" ]; then
    fail c "handoff dir not created: $handoff_dir"
  else
    local count
    count=$(find "$handoff_dir" -type f -name '*.tsv' | wc -l | tr -d ' ')
    if [ "$count" -lt 1 ]; then
      fail c "no handoff record written under $handoff_dir"
    else
      # Verify the record names the artifact path.
      if ! grep -Fq "$artifact" "$handoff_dir"/*.tsv 2>/dev/null; then
        fail c "handoff record does not reference artifact path"
      else
        pass c "handoff record written and artifact retained"
      fi
    fi
  fi
  rm -rf "$home"
}

# Scenario (d): STUDIO_KEEP_ARTIFACTS=1 retains everything + emits stderr audit
run_d() {
  local home; home=$(make_sandbox)
  local artifact="$home/scratch-d"
  mkdir -p "$artifact"
  local stderr_log="$home/stderr.log"
  (
    export HOME="$home"
    export ACHILLES_PROJECT="lac-fixture"
    export STUDIO_KEEP_ARTIFACTS=1
    # shellcheck source=/dev/null
    . "$LIB"
    register_artifact tmpdir "$artifact"
    exit 0
  ) 2>"$stderr_log"
  if [ ! -e "$artifact" ]; then
    fail d "artifact deleted despite STUDIO_KEEP_ARTIFACTS=1: $artifact"
  fi
  if ! grep -q 'STUDIO_KEEP_ARTIFACTS=1' "$stderr_log"; then
    fail d "no stderr audit line emitted (log: $stderr_log)"
  else
    pass d "retained artifact and emitted audit line"
  fi
  rm -rf "$home"
}

run_a
run_b
run_c
run_d

if [ "$FAIL" -gt 0 ]; then
  printf 'lib-artifact-cleanup-fixture: %d failure(s)\n' "$FAIL" >&2
  exit 1
fi
printf 'lib-artifact-cleanup-fixture: all 4 scenarios passed\n'
exit 0
