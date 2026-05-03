#!/usr/bin/env bash
# Verifies autonomous chain supervisor start/resume/refusal decisions.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-supervisor.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

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
  "title": "Supervisor fixture $issue",
  "body": "Exercise supervisor behavior.",
  "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/$issue",
  "state": "OPEN"
}
JSON
  exit 0
fi

if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

manifest="$TMPROOT/supervisor.yaml"
cat > "$manifest" <<'YAML'
schema_version: 1
chains:
  - name: supervisor-a
    base: main
    branch: feature/supervisor-a
    host: codex
    issues: [481]
YAML
manifest_real=$(cd "$(dirname "$manifest")" && pwd -P)/$(basename "$manifest")
chain_root="$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs"

write_state() {
  run_id="$1"
  status="$2"
  extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  run_dir="$chain_root/$run_id"
  mkdir -p "$run_dir"
  jq -n \
    --arg run_id "$run_id" \
    --arg manifest "$manifest_real" \
    --arg status "$status" \
    --arg run_dir "$run_dir" \
    --argjson extra "$extra" \
    '{
      schema_version: 1,
      run_id: $run_id,
      manifest: $manifest,
      status: $status,
      started_at: "2026-05-03T00:00:00Z",
      updated_at: "2026-05-03T00:00:01Z",
      report: ($run_dir + "/report.md"),
      plan: ($run_dir + "/plan.json"),
      parallel_chains: "1",
      chains: [
        {
          name: "supervisor-a",
          base: "main",
          branch: "feature/supervisor-a",
          host: "codex",
          chain_run_id: "019df000-0000-7000-a000-000000000001",
          chain_worktree: "/tmp/studio-chain-runner/supervisor-a-feature",
          worker_pool: 1,
          status: "pending",
          issues: [
            {
              number: 481,
              title: "Supervisor fixture 481",
              state: "OPEN",
              issue_branch: "feature/supervisor-a-issue-481",
              issue_worktree: "/tmp/studio-chain-runner/supervisor-a-issue-481",
              issue_run_id: "019df000-0000-7000-a000-000000000002",
              status: "pending"
            }
          ]
        }
      ],
      halt_records: [],
      decision_escrows: [],
      failure_reason: null
    } + $extra' > "$run_dir/state.json"
}

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --explain-next "$manifest" > "$TMPROOT/explain-start.out" 2>&1
grep -q '"action":"start"' "$TMPROOT/explain-start.out" || {
  printf 'explain-next did not choose start\n' >&2
  cat "$TMPROOT/explain-start.out" >&2
  exit 1
}
[ ! -d "$chain_root" ] || {
  printf 'explain-next unexpectedly created chain state\n' >&2
  find "$chain_root" -maxdepth 2 -type f >&2
  exit 1
}

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --auto "$manifest" --dry-run > "$TMPROOT/auto-start.out" 2>&1
grep -q '"action":"start"' "$TMPROOT/auto-start.out" || {
  printf 'auto dry-run did not choose start\n' >&2
  cat "$TMPROOT/auto-start.out" >&2
  exit 1
}
grep -q 'DRY-RUN git worktree add' "$TMPROOT/auto-start.out" || {
  printf 'auto dry-run did not reach existing runner execution path\n' >&2
  cat "$TMPROOT/auto-start.out" >&2
  exit 1
}

rm -rf "$chain_root"
write_state "019df000-0000-7000-a000-000000000010" "failed"
PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --auto "$manifest" --dry-run > "$TMPROOT/auto-resume.out" 2>&1
grep -q '"action":"resume"' "$TMPROOT/auto-resume.out" || {
  printf 'auto dry-run did not choose resume\n' >&2
  cat "$TMPROOT/auto-resume.out" >&2
  exit 1
}
grep -q '019df000-0000-7000-a000-000000000010' "$TMPROOT/auto-resume.out" || {
  printf 'auto resume did not preserve selected run id\n' >&2
  cat "$TMPROOT/auto-resume.out" >&2
  exit 1
}

rm -rf "$chain_root"
write_state "019df000-0000-7000-a000-000000000020" "failed"
write_state "019df000-0000-7000-a000-000000000021" "planned"
if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --auto "$manifest" > "$TMPROOT/ambiguous.out" 2>&1; then
  printf 'ambiguous auto selection unexpectedly passed\n' >&2
  cat "$TMPROOT/ambiguous.out" >&2
  exit 1
fi
grep -q '"action":"refused_ambiguous"' "$TMPROOT/ambiguous.out" || {
  printf 'ambiguous refusal missing decision payload\n' >&2
  cat "$TMPROOT/ambiguous.out" >&2
  exit 1
}
grep -q -- '--resume <run_id> --yes' "$TMPROOT/ambiguous.out" || {
  printf 'ambiguous refusal missing manual selector guidance\n' >&2
  cat "$TMPROOT/ambiguous.out" >&2
  exit 1
}

rm -rf "$chain_root"
hard_run="019df000-0000-7000-a000-000000000030"
write_state "$hard_run" "failed"
hard_dir="$chain_root/$hard_run"
cat > "$hard_dir/hard.json" <<JSON
{"schema_version":1,"kind":"chain-halt-record","true_hard_stop":true}
JSON
jq --arg path "$hard_dir/hard.json" '.halt_records = [{path:$path, reason_id:"secret_detected", halt_class:"fatal"}]' "$hard_dir/state.json" > "$hard_dir/state.json.tmp"
mv "$hard_dir/state.json.tmp" "$hard_dir/state.json"
if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --auto "$manifest" > "$TMPROOT/hard-stop.out" 2>&1; then
  printf 'hard-stop auto selection unexpectedly passed\n' >&2
  cat "$TMPROOT/hard-stop.out" >&2
  exit 1
fi
grep -q '"action":"refused_hard_stop"' "$TMPROOT/hard-stop.out" || {
  printf 'hard-stop refusal missing decision payload\n' >&2
  cat "$TMPROOT/hard-stop.out" >&2
  exit 1
}

rm -rf "$chain_root"
escrow_run="019df000-0000-7000-a000-000000000040"
write_state "$escrow_run" "failed" '{"decision_escrows":[{"path":"escrow.json","decision_id":"needs-review"}]}'
if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --auto "$manifest" > "$TMPROOT/escrow.out" 2>&1; then
  printf 'escrow auto selection unexpectedly passed\n' >&2
  cat "$TMPROOT/escrow.out" >&2
  exit 1
fi
grep -q '"action":"refused_escrow"' "$TMPROOT/escrow.out" || {
  printf 'escrow refusal missing decision payload\n' >&2
  cat "$TMPROOT/escrow.out" >&2
  exit 1
}

rm -rf "$chain_root"
lock_run="019df000-0000-7000-a000-000000000050"
write_state "$lock_run" "failed"
mkdir "$chain_root/$lock_run/state.json.lock"
printf '%s\n' "$$" > "$chain_root/$lock_run/state.json.lock/pid"
if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --auto "$manifest" > "$TMPROOT/lock.out" 2>&1; then
  printf 'lock-held auto selection unexpectedly passed\n' >&2
  cat "$TMPROOT/lock.out" >&2
  exit 1
fi
grep -q '"action":"refused_lock"' "$TMPROOT/lock.out" || {
  printf 'lock refusal missing decision payload\n' >&2
  cat "$TMPROOT/lock.out" >&2
  exit 1
}

rm -rf "$chain_root"
write_state "019df000-0000-7000-a000-000000000060" "completed"
PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --explain-next "$manifest" > "$TMPROOT/complete.out" 2>&1
grep -q '"action":"already_complete"' "$TMPROOT/complete.out" || {
  printf 'explain-next did not report completed terminal run\n' >&2
  cat "$TMPROOT/complete.out" >&2
  exit 1
}

printf 'PASS: chain supervisor decisions\n'
