#!/usr/bin/env bash
# Verifies chain-runner run namespacing, artifact hygiene, and explicit resume semantics.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t chain-artifact-hygiene.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
HOME_DIR="$TMPROOT/home"
TMPDIR_ROOT="$TMPROOT/tmp"
mkdir -p "$BIN" "$HOME_DIR" "$TMPDIR_ROOT"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  issue="$3"
  cat <<JSON
{
  "number": $issue,
  "title": "Artifact hygiene fixture $issue",
  "body": "Exercise artifact hygiene.",
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

manifest="$TMPROOT/artifact-hygiene.yaml"
cat > "$manifest" <<'YAML'
schema_version: 1
chains:
  - name: artifact-hygiene
    base: main
    branch: feature/artifact-hygiene
    host: codex
    issues: [651]
YAML
manifest_real=$(cd "$(dirname "$manifest")" && pwd -P)/$(basename "$manifest")
chain_root="$HOME_DIR/.dev-studio/generic-dev-studio/chain-runs"
tmp_chain_root="$TMPDIR_ROOT/studio-chain-runner"

PATH="$BIN:$PATH" HOME="$HOME_DIR" TMPDIR="$TMPDIR_ROOT/" \
  "$ROOT/scripts/studio-chain-runner.sh" "$manifest" --dry-run > "$TMPROOT/dry-run.out" 2>&1

run_id=$(sed -n 's/^- Run UUID: `\(.*\)`$/\1/p' "$TMPROOT/dry-run.out" | head -1)
[ -n "$run_id" ] || {
  printf 'dry-run did not print a run UUID\n' >&2
  cat "$TMPROOT/dry-run.out" >&2
  exit 1
}
grep -q "studio-chain-runner/$run_id/artifact-hygiene-feature" "$TMPROOT/dry-run.out" || {
  printf 'chain worktree was not namespaced by run id\n' >&2
  cat "$TMPROOT/dry-run.out" >&2
  exit 1
}
grep -q "studio-chain-runner/$run_id/artifact-hygiene-issue-651" "$TMPROOT/dry-run.out" || {
  printf 'issue worktree was not namespaced by run id\n' >&2
  cat "$TMPROOT/dry-run.out" >&2
  exit 1
}

mkdir -p "$chain_root/old-failed" "$chain_root/old-failed/state.json.lock" "$tmp_chain_root/old-temp"
printf '999999999\n' > "$chain_root/old-failed/state.json.lock/pid"
jq -n \
  --arg manifest "$TMPROOT/other-chain.yaml" \
  '{schema_version:1, run_id:"old-failed", manifest:$manifest, status:"failed", started_at:"2026-05-01T00:00:00Z", updated_at:"2026-05-01T00:00:01Z"}' \
  > "$chain_root/old-failed/state.json"
printf 'this artifact is intentionally large enough for gzip\n' > "$chain_root/old-failed/events.jsonl"
touch -t 202001010000 "$tmp_chain_root/old-temp"

PATH="$BIN:$PATH" HOME="$HOME_DIR" TMPDIR="$TMPDIR_ROOT/" STUDIO_CHAIN_ARTIFACT_MAX_BYTES=10 STUDIO_CHAIN_TMP_RETENTION_DAYS=1 \
  "$ROOT/scripts/studio-chain-runner.sh" "$manifest" > "$TMPROOT/plan.out" 2>&1

[ ! -d "$chain_root/old-failed/state.json.lock" ] || {
  printf 'stale state lock was not removed\n' >&2
  find "$chain_root/old-failed" -maxdepth 2 -print >&2
  exit 1
}
[ -f "$chain_root/old-failed/events.jsonl.gz" ] || {
  printf 'oversized private artifact was not archived\n' >&2
  find "$chain_root/old-failed" -maxdepth 2 -type f -print >&2
  exit 1
}
[ ! -d "$tmp_chain_root/old-temp" ] || {
  printf 'old temporary run root was not pruned\n' >&2
  find "$tmp_chain_root" -maxdepth 2 -type d -print >&2
  exit 1
}

state_path=$(sed -n 's/^- State: `\(.*\)`$/\1/p' "$TMPROOT/plan.out" | head -1)
planned_run_id=$(jq -r '.run_id' "$state_path")
PATH="$BIN:$PATH" HOME="$HOME_DIR" TMPDIR="$TMPDIR_ROOT/" \
  "$ROOT/scripts/studio-chain-runner.sh" --auto "$manifest" --dry-run > "$TMPROOT/auto-resume.out" 2>&1
grep -q '"action":"resume"' "$TMPROOT/auto-resume.out" || {
  printf 'auto dry-run did not choose the planned run for resume\n' >&2
  cat "$TMPROOT/auto-resume.out" >&2
  exit 1
}
grep -q "scripts/studio-chain-runner.sh --resume $planned_run_id --yes" "$TMPROOT/auto-resume.out" || {
  printf 'resume command was not explicit\n' >&2
  cat "$TMPROOT/auto-resume.out" >&2
  exit 1
}
grep -q 'completed but unintegrated issues are integrated before new work starts' "$TMPROOT/auto-resume.out" || {
  printf 'deterministic resume semantics were not surfaced\n' >&2
  cat "$TMPROOT/auto-resume.out" >&2
  exit 1
}

printf 'PASS: chain artifact hygiene\n'
