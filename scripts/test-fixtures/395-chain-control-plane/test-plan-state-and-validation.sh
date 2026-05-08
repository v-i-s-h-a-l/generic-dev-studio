#!/usr/bin/env bash
# Verifies chain-runner plan-by-default state and graph validation.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-chain-control.XXXXXX)
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
  "title": "Control plane fixture $issue",
  "body": "Exercise control-plane behavior.",
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
  - name: control-a
    base: main
    branch: feature/control-a
    host: codex
    phase_review: required
    issues: [395]
YAML

PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$manifest" > "$TMPROOT/plan.out" 2>&1

grep -q '# Studio Chain Plan' "$TMPROOT/plan.out" || {
  printf 'missing default plan output\n' >&2
  cat "$TMPROOT/plan.out" >&2
  exit 1
}
grep -q 'rerun with --yes' "$TMPROOT/plan.out" || {
  printf 'missing explicit execution escape hatch\n' >&2
  cat "$TMPROOT/plan.out" >&2
  exit 1
}
if grep -q 'DRY-RUN git worktree add' "$TMPROOT/plan.out"; then
  printf 'default plan unexpectedly entered execution path\n' >&2
  cat "$TMPROOT/plan.out" >&2
  exit 1
fi

state_path=$(sed -n 's/^- State: `\(.*\)`$/\1/p' "$TMPROOT/plan.out" | head -1)
[ -n "$state_path" ] || {
  printf 'missing state path in plan output\n' >&2
  cat "$TMPROOT/plan.out" >&2
  exit 1
}
jq -e '
  .schema_version == 1 and
  .status == "planned" and
  (.chains | length) == 1 and
  .chains[0].phase_review == "required" and
  .chains[0].chain_run_id != null and
  .chains[0].issues[0].issue_run_id != null and
  .chains[0].issues[0].status == "pending" and
  .chains[0].issues[0].lifecycle_state == "issue-created" and
  .chains[0].issues[0].provenance.issue.number == 395 and
  .chains[0].issues[0].provenance.issue.repo == "v-i-s-h-a-l/generic-dev-studio"
' "$state_path" >/dev/null

run_id=$(jq -r '.run_id' "$state_path")
PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" --resume "$run_id" --dry-run > "$TMPROOT/resume.out" 2>&1
grep -q "$run_id" "$TMPROOT/resume.out" || {
  printf 'resume dry-run did not preserve run id\n' >&2
  cat "$TMPROOT/resume.out" >&2
  exit 1
}

duplicate_manifest="$TMPROOT/duplicate.yaml"
cat > "$duplicate_manifest" <<'YAML'
schema_version: 1
chains:
  - name: control-a
    base: main
    branch: feature/control-a
    host: codex
    issues: [395]
  - name: control-b
    base: main
    branch: feature/control-b
    host: codex
    issues: [395]
YAML

if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$duplicate_manifest" --dry-run > "$TMPROOT/dup.out" 2>&1; then
  printf 'duplicate issue manifest unexpectedly passed\n' >&2
  cat "$TMPROOT/dup.out" >&2
  exit 1
fi
grep -q 'duplicate issue IDs across chains: 395' "$TMPROOT/dup.out" || {
  printf 'duplicate issue failure was not explained\n' >&2
  cat "$TMPROOT/dup.out" >&2
  exit 1
}

bad_phase_manifest="$TMPROOT/bad-phase-review.yaml"
cat > "$bad_phase_manifest" <<'YAML'
schema_version: 1
chains:
  - name: control-bad-phase
    base: main
    branch: feature/control-bad-phase
    host: codex
    phase_review: sometimes
    issues: [395]
YAML

if PATH="$BIN:$PATH" HOME="$HOME_DIR" "$ROOT/scripts/studio-chain-runner.sh" "$bad_phase_manifest" --dry-run > "$TMPROOT/bad-phase.out" 2>&1; then
  printf 'bad phase_review manifest unexpectedly passed\n' >&2
  cat "$TMPROOT/bad-phase.out" >&2
  exit 1
fi
grep -q 'phase_review must be required, auto, or off' "$TMPROOT/bad-phase.out" || {
  printf 'bad phase_review failure was not explained\n' >&2
  cat "$TMPROOT/bad-phase.out" >&2
  exit 1
}

printf 'PASS: chain-runner control-plane plan/state validation\n'
