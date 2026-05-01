#!/usr/bin/env bash
# Regression fixture for the brief quality contract.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t brief-quality.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0

assert() {
  local name="$1" expr="$2"
  if eval "$expr"; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    fail=$((fail + 1))
  fi
}

write_good() {
  local path="$1" size="${2:-s}" extra_body="${3:-}"
  cat > "$path" <<YAML
schema_version: {name: brief, version: 3.8.0, min_reader: 3.0.0, deprecated_at: null}
id: brief-323-good
task_id: ""
type: impl
size: $size
state: draft
acceptance:
  - Settings screen shows the retry banner only after a failed sync response.
  - Tapping Retry invokes SyncService.retry once in the unit test harness.
testability: []
recommended_models:
  best_result: {tier: sonnet, model_id: claude-sonnet-default, reasoning_effort: medium}
  fast_turnaround: {tier: haiku, model_id: claude-haiku-default, reasoning_effort: low}
  rationale: "Small implementation against an existing sync pattern."
summary: "Add retry banner for failed settings sync. It gives users a clear recovery path. Keep service injection unchanged."
body: |
  # Task Brief: T323 - Retry banner

  ## Objective
  Show a retry banner on the settings screen after sync failure and route the Retry action through the existing sync service.

$extra_body
  ## Acceptance Criteria
  1. Settings screen shows the retry banner only after a failed sync response.
  2. Tapping Retry invokes SyncService.retry once in the unit test harness.

  ## Verification / Evidence
  - Run SettingsSyncViewModelTests.retryBanner.
  - Debrief includes the test output or a manual note explaining why it was not run.

  ## Non-goals / Out of Scope
  - Do not change sync scheduling.
  - Do not redesign settings layout.
YAML
}

write_good "$TMPROOT/good.yaml"
bash "$ROOT/scripts/validate-brief.sh" "$TMPROOT/good.yaml" >"$TMPROOT/good.out" 2>"$TMPROOT/good.err"
good_rc=$?

cat > "$TMPROOT/bad.yaml" <<'YAML'
schema_version: {name: brief, version: 3.8.0, min_reader: 3.0.0, deprecated_at: null}
id: brief-323-bad
task_id: ""
type: impl
size: s
state: draft
acceptance:
  - The experience feels polished and works well.
testability: []
summary: "Bad brief."
body: |
  # Task Brief: T323 - Bad
YAML
bash "$ROOT/scripts/validate-brief.sh" "$TMPROOT/bad.yaml" >"$TMPROOT/bad.out" 2>"$TMPROOT/bad.err"
bad_rc=$?

write_good "$TMPROOT/l-no-waiver.yaml" l
bash "$ROOT/scripts/validate-brief.sh" "$TMPROOT/l-no-waiver.yaml" >"$TMPROOT/l-no-waiver.out" 2>"$TMPROOT/l-no-waiver.err"
l_no_waiver_rc=$?

write_good "$TMPROOT/l-waiver.yaml" l "  ## Split Rationale
  This touches one generated migration boundary where splitting would create two incompatible intermediate states."
bash "$ROOT/scripts/validate-brief.sh" "$TMPROOT/l-waiver.yaml" >"$TMPROOT/l-waiver.out" 2>"$TMPROOT/l-waiver.err"
l_waiver_rc=$?

cat > "$TMPROOT/legacy.yaml" <<'YAML'
schema_version: {name: brief, version: 3.7.0, min_reader: 3.0.0, deprecated_at: null}
id: brief-323-legacy
task_id: ""
type: impl
size: s
state: draft
acceptance: []
testability: []
body: |
  # Legacy brief shape
YAML
bash "$ROOT/scripts/validate-brief.sh" "$TMPROOT/legacy.yaml" >"$TMPROOT/legacy.out" 2>"$TMPROOT/legacy.err"
legacy_rc=$?

export HOME="$TMPROOT/home"
export ACHILLES_PROJECT="brief-quality-project"
mkdir -p "$HOME/.dev-studio/$ACHILLES_PROJECT/plans/tasks" \
  "$HOME/.dev-studio/$ACHILLES_PROJECT/plans/briefs" \
  "$HOME/.dev-studio/$ACHILLES_PROJECT/events"
# shellcheck source=../../../scripts/lib-ledger.sh
. "$ROOT/scripts/lib-ledger.sh"

writer_task_uuid=$(mint_uuidv7)
writer_default_uuid=$(mint_uuidv7)
writer_38_uuid=$(mint_uuidv7)
write_task_artifact "$writer_task_uuid" proposed "Writer schema test" >/dev/null
printf '## Objective\nWriter schema test.\n' > "$TMPROOT/writer-body.md"
write_brief_artifact "$writer_default_uuid" "$writer_task_uuid" impl s \
  awaiting_user=false \
  body_file="$TMPROOT/writer-body.md" >/dev/null
write_brief_artifact "$writer_38_uuid" "$writer_task_uuid" impl s \
  awaiting_user=false \
  schema_version=3.8.0 \
  acceptance='["Writer opt-in acceptance is objectively verifiable."]' \
  recommended_models='{"best_result":{"tier":"sonnet","reasoning_effort":"medium"},"fast_turnaround":{"tier":"haiku","reasoning_effort":"low"},"rationale":"Fixture opt-in."}' \
  body_file="$TMPROOT/writer-body.md" >/dev/null
writer_default_version=$(yq -r '.schema_version.version' "$HOME/.dev-studio/$ACHILLES_PROJECT/plans/briefs/$writer_default_uuid.yaml")
writer_38_version=$(yq -r '.schema_version.version' "$HOME/.dev-studio/$ACHILLES_PROJECT/plans/briefs/$writer_38_uuid.yaml")

assert "valid brief@3.8.0 quality contract passes" "[ $good_rc -eq 0 ]"
assert "weak brief@3.8.0 fails" "[ $bad_rc -ne 0 ]"
assert "weak brief failure names quality rules" "grep -q 'R-QUAL-OBJECTIVE' '$TMPROOT/bad.err' && grep -q 'R-QUAL-MODEL' '$TMPROOT/bad.err'"
assert "L executable brief without waiver fails" "[ $l_no_waiver_rc -ne 0 ]"
assert "L executable failure names size rule" "grep -q 'R-QUAL-SIZE' '$TMPROOT/l-no-waiver.err'"
assert "L executable brief with split rationale passes" "[ $l_waiver_rc -eq 0 ]"
assert "pre-3.8 legacy brief is not retroactively blocked" "[ $legacy_rc -eq 0 ]"
assert "writer defaults legacy/backfill briefs below 3.8" "[ '$writer_default_version' = '3.7.0' ]"
assert "writer supports explicit brief@3.8.0 opt-in" "[ '$writer_38_version' = '3.8.0' ]"

printf '%s assertions, %s failures\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
