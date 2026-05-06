#!/usr/bin/env bash
# Verifies single-chain scheduling dispatches ready issues and preserves dependency order.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-scheduler.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
mkdir -p "$BIN" "$HOME_DIR"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "Scheduler fixture $issue",
  "body": "Exercise dependency-ready scheduling.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/$issue",
  "state": "OPEN"
}
JSON
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

manifest="$TMPROOT/chain.yaml"
cat > "$manifest" <<'YAML'
schema_version: 1
chains:
  - name: scheduler-fixture
    base: main
    branch: feature/scheduler-fixture
    host: codex
    phase_review: off
    issues:
      - number: 64901
      - number: 64902
      - number: 64903
        dependencies: [64901]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" STUDIO_CHAIN_WORKER_POOL=2 \
  "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --dry-run > "$TMPROOT/out" 2>&1

awk '
  /studio-chain-runner: issue #64901 ->/ { issue_one=NR }
  /studio-chain-runner: issue #64902 ->/ { issue_two=NR }
  /DRY-RUN git -C .*merge --ff-only FETCH_HEAD/ && !first_merge { first_merge=NR }
  /studio-chain-runner: issue #64903 ->/ { issue_three=NR }
  END {
    exit !(issue_one && issue_two && first_merge && issue_three &&
      issue_one < first_merge && issue_two < first_merge && first_merge < issue_three)
  }
' "$TMPROOT/out" || {
  cat "$TMPROOT/out" >&2
  fail "independent ready issues did not dispatch before dependent issue"
}

blocked_manifest="$TMPROOT/blocked.yaml"
cat > "$blocked_manifest" <<'YAML'
schema_version: 1
chains:
  - name: blocked-fixture
    base: main
    branch: feature/blocked-fixture
    host: codex
    phase_review: off
    issues:
      - number: 64911
        dependencies: [64912]
      - number: 64912
        dependencies: [64911]
YAML

if PATH="$BIN:$PATH" HOME="$HOME_DIR" STUDIO_CHAIN_WORKER_POOL=2 \
  "$ROOT/scripts/studio-chain-runner.sh" "$blocked_manifest" --dry-run > "$TMPROOT/blocked.out" 2>&1; then
  cat "$TMPROOT/blocked.out" >&2
  fail "blocked graph unexpectedly completed"
fi

grep -q 'chain graph blocked: no pending issue has all dependencies completed' "$TMPROOT/blocked.out" || {
  cat "$TMPROOT/blocked.out" >&2
  fail "blocked graph did not report a scheduler halt reason"
}

awk '
  /elif ! issue_job_is_running "\$pid"/ { detected=1 }
  /worker exited before writing result/ && detected { result=1 }
  END { exit !(detected && result) }
' "$ROOT/scripts/studio-chain-runner.sh" || fail "scheduler does not convert crashed workers without result files into failures"

printf 'PASS: chain scheduler\n'
