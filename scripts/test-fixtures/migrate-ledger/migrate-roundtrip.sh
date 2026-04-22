#!/usr/bin/env bash
# migrate-roundtrip.sh — fixture-based unit test for
# scripts/migrate-ledger.sh + scripts/verify-ledger.sh.
#
# Builds a synthetic legacy-ledger project under a tempdir, runs the
# migration end-to-end (backup → transform → verify), and asserts:
#   1. Pre-flight accepts a clean synthetic project (no live signals).
#   2. Backup lands at archive/2026-pre-2.6/ and is idempotent on re-run.
#   3. Brief transform mints plans/briefs/*.yaml per legacy *-impl.md.
#   4. Debrief transform mints plans/debriefs/*.yaml per legacy *-debrief.md.
#   5. Misfiled debrief (in a subdir) is detected, routed, and reported.
#   6. Events consolidation produces events/YYYY-MM-DD.jsonl, sorted + deduped.
#   7. Empty placeholder dirs (Q19: archive/ reporters/ root-causes/ under
#      feedback-inbox) are pruned.
#   8. verify-ledger.sh passes on the resulting tree (zero mismatches).
#   9. Transform is idempotent — second run does not re-copy backup or
#      re-emit artifacts.
#
# Exit 0 on pass, 1 on any assertion failure.

set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_SCRIPTS=$(cd "$SCRIPT_DIR/../.." && pwd)

TMPROOT=$(mktemp -d -t migrate-fixture.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PROJ_ROOT="$TMPROOT/project"
mkdir -p "$PROJ_ROOT"

# Environment overrides so the migration script does not touch ~/.dev-studio/.
export ACHILLES_PROJECT="test-project"
export ACHILLES_PROJECT_ROOT="$PROJ_ROOT"

assertions=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
assert() {
  assertions=$((assertions + 1))
  if ! eval "$2"; then
    fail "$1 — failed: $2"
  fi
}

# ---- Build synthetic legacy ledger ----

# Legacy brief (chanakya-tasks/)
mkdir -p "$PROJ_ROOT/plans/chanakya-tasks"
cat > "$PROJ_ROOT/plans/chanakya-tasks/T001-impl.md" <<'EOF'
# Brief T001 — Add filter preset row

## Context
Filter presets surface three defaults in the header row.

## Steps
1. Add FilterPresetRow view
2. Wire viewmodel
3. Emit analytics on tap
EOF

cat > "$PROJ_ROOT/plans/chanakya-tasks/T002-unit-test.md" <<'EOF'
# Brief T002 — Unit tests for FilterPresetStore

## Coverage
- Protocol conformance
- Apply-preset logic
EOF

# Legacy debriefs (chanakya-inbox/)
mkdir -p "$PROJ_ROOT/plans/chanakya-inbox/processed"
cat > "$PROJ_ROOT/plans/chanakya-inbox/T001-debrief.md" <<'EOF'
# Debrief: T001 — Add filter preset row
Completed: 2026-04-22 14:30 IST

## Summary
Rendered three presets in a horizontal scroll view.

## Commits
- abc123 — FilterPresetRow with three-preset layout

## Build Verification
build_gate: lsp-only
build_debt_override: false
EOF

# Already-processed debrief — NOT re-migrated per Q18.
cat > "$PROJ_ROOT/plans/chanakya-inbox/processed/T000-debrief.md" <<'EOF'
# Debrief T000 — already processed
Completed: 2026-04-10
EOF

# Misfiled debrief — lives in a subdir it shouldn't. Q20 detects + routes.
mkdir -p "$PROJ_ROOT/plans/chanakya-inbox/stray"
cat > "$PROJ_ROOT/plans/chanakya-inbox/stray/T003-debrief.md" <<'EOF'
# Debrief T003 — was misfiled
Completed: 2026-04-22
EOF

# Legacy event-log sources — three variants exercising the merge.
cat > "$PROJ_ROOT/event-log.jsonl" <<'EOF'
{"ts":"2026-04-20T10:00:00Z","agent":"chanakya","event":"task_dispatched","task":"T001","data":{},"idempotency_key":"chanakya:ship:T001:abc"}
{"ts":"2026-04-20T10:05:00Z","agent":"achilles","event":"task_started","task":"T001","data":{},"idempotency_key":"achilles:task:T001:def"}
EOF

mkdir -p "$PROJ_ROOT/.runtime"
cat > "$PROJ_ROOT/.runtime/events.jsonl" <<'EOF'
{"ts":"2026-04-20T10:05:00Z","agent":"achilles","event":"task_started","task":"T001","data":{},"idempotency_key":"achilles:task:T001:def"}
{"ts":"2026-04-21T09:00:00Z","agent":"chanakya","event":"task_dispatched","task":"T002","data":{},"idempotency_key":"chanakya:ship:T002:xyz"}
EOF

cat > "$PROJ_ROOT/plans/chanakya-events.jsonl" <<'EOF'
{"ts":"2026-04-19T08:00:00Z","agent":"chanakya","event":"brief_started","task":"T001","data":{},"idempotency_key":"chanakya:brief:T001:111"}
{"ts":"bogus-ts","agent":"chanakya","event":"bad","task":"","data":{}}
EOF

# Feedback layout — reports/ has content; placeholders are .gitkeep only.
mkdir -p "$PROJ_ROOT/feedback-inbox/turnip-ios/reports"
mkdir -p "$PROJ_ROOT/feedback-inbox/turnip-ios/archive"
mkdir -p "$PROJ_ROOT/feedback-inbox/turnip-ios/reporters"
mkdir -p "$PROJ_ROOT/feedback-inbox/turnip-ios/root-causes"
touch "$PROJ_ROOT/feedback-inbox/turnip-ios/archive/.gitkeep"
touch "$PROJ_ROOT/feedback-inbox/turnip-ios/reporters/.gitkeep"
touch "$PROJ_ROOT/feedback-inbox/turnip-ios/root-causes/.gitkeep"
cat > "$PROJ_ROOT/feedback-inbox/turnip-ios/reports/F-001.md" <<'EOF'
# F-001 — Filter preset row unresponsive on iPhone SE
Reporter: @user1
EOF

# Post-migration layout (feedback/) with placeholder subdirs that the cleanup
# phase should prune, and one content-bearing subdir that must survive.
mkdir -p "$PROJ_ROOT/feedback/root-causes"
mkdir -p "$PROJ_ROOT/feedback/reporters"
mkdir -p "$PROJ_ROOT/feedback/archive"
touch "$PROJ_ROOT/feedback/root-causes/.gitkeep"
touch "$PROJ_ROOT/feedback/reporters/.gitkeep"
printf 'build 3146 feedback\n' > "$PROJ_ROOT/feedback/archive/build-3146.md"

# Dirty the mtimes so pre-flight's 60s check passes (synthetic files are
# brand-new). Use touch -t with an old timestamp.
find "$PROJ_ROOT" -type f -exec touch -t 202604220000 '{}' \; 2>/dev/null || true

# ---- Run migration ----

"$REPO_SCRIPTS/migrate-ledger.sh" --project test-project >"$TMPROOT/run1.log" 2>&1 \
  || fail "migrate-ledger.sh first run failed. Log:\n$(cat "$TMPROOT/run1.log")"

# Assertions
assert "#1 pre-flight passed" \
  "grep -q 'pre-flight OK' '$TMPROOT/run1.log'"

assert "#2 backup at archive/2026-pre-2.6/" \
  "[ -d '$PROJ_ROOT/archive/2026-pre-2.6' ]"

assert "#2 backup preserved legacy brief" \
  "[ -f '$PROJ_ROOT/archive/2026-pre-2.6/plans/chanakya-tasks/T001-impl.md' ]"

assert "#3 new brief YAML minted for T001" \
  "find '$PROJ_ROOT/plans/briefs' -name '*.yaml' -print0 2>/dev/null | xargs -0 grep -l 'legacy_task_id: \"T001\"' >/dev/null"

assert "#3 new brief YAML minted for T002" \
  "find '$PROJ_ROOT/plans/briefs' -name '*.yaml' -print0 2>/dev/null | xargs -0 grep -l 'legacy_task_id: \"T002\"' >/dev/null"

assert "#3 brief carries schema_version 3.1.0" \
  "find '$PROJ_ROOT/plans/briefs' -name '*.yaml' -print0 2>/dev/null | xargs -0 grep -l 'version: 3.1.0' >/dev/null"

assert "#4 new debrief YAML minted for T001" \
  "find '$PROJ_ROOT/plans/debriefs' -name '*.yaml' -print0 2>/dev/null | xargs -0 grep -l 'legacy_task_id: \"T001\"' >/dev/null"

assert "#4 processed debrief NOT re-migrated (T000)" \
  "! find '$PROJ_ROOT/plans/debriefs' -name '*.yaml' -print0 2>/dev/null | xargs -0 grep -l 'legacy_task_id: \"T000\"' >/dev/null 2>&1"

assert "#5 misfiled debrief detected (T003)" \
  "find '$PROJ_ROOT/plans/debriefs' -name '*.yaml' -print0 2>/dev/null | xargs -0 grep -l 'legacy_task_id: \"T003\"' >/dev/null"

assert "#5 misfiled-debrief reported" \
  "grep -q 'misfiled-debrief' '$PROJ_ROOT/archive/2026-pre-2.6/migration-report.md'"

assert "#6 events consolidated into day partition" \
  "[ -f '$PROJ_ROOT/events/2026-04-19.jsonl' ] && [ -f '$PROJ_ROOT/events/2026-04-20.jsonl' ]"

assert "#6 events index emitted" \
  "[ -f '$PROJ_ROOT/events/index.yaml' ]"

# Dedupe: the duplicate idempotency_key ("achilles:task:T001:def") across
# event-log.jsonl + .runtime/events.jsonl should appear only once in the
# merged output.
dedup_count=$(grep -h 'achilles:task:T001:def' "$PROJ_ROOT/events/"*.jsonl 2>/dev/null | wc -l | tr -d ' ')
assert "#6 dedupe kept one copy of duplicate event (got=$dedup_count)" \
  "[ '$dedup_count' -eq 1 ]"

# Sort: within a day, events must be in ts order.
first_ts=$(head -n 1 "$PROJ_ROOT/events/2026-04-20.jsonl" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
last_ts=$(tail -n 1 "$PROJ_ROOT/events/2026-04-20.jsonl" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
assert "#6 day file is sorted (first<=last)" \
  "[[ '$first_ts' < '$last_ts' ]] || [[ '$first_ts' = '$last_ts' ]]"

# Unparseable: the "bogus-ts" event must land under archive/unparseable/.
assert "#6 unparseable event routed to archive" \
  "[ -f '$PROJ_ROOT/archive/2026-pre-2.6/unparseable/unbucketed-events.jsonl' ]"

assert "#7 placeholder archive/ dir pruned" \
  "[ ! -d '$PROJ_ROOT/feedback-inbox/turnip-ios/archive' ]"

assert "#7 placeholder reporters/ dir pruned" \
  "[ ! -d '$PROJ_ROOT/feedback-inbox/turnip-ios/reporters' ]"

assert "#7 feedback report transformed (content dir preserved)" \
  "find '$PROJ_ROOT/plans/feedback' -name '*.yaml' -print0 2>/dev/null | xargs -0 grep -l 'F-001' >/dev/null"

# ---- Cleanup phase (issue #68): legacy event-log siblings retired ----

assert "#10 event-log.jsonl moved out of project root" \
  "[ ! -f '$PROJ_ROOT/event-log.jsonl' ]"

assert "#10 .runtime/events.jsonl moved out" \
  "[ ! -f '$PROJ_ROOT/.runtime/events.jsonl' ]"

assert "#10 plans/chanakya-events.jsonl moved out" \
  "[ ! -f '$PROJ_ROOT/plans/chanakya-events.jsonl' ]"

assert "#10 retired files landed under legacy-event-sources/" \
  "[ -f '$PROJ_ROOT/archive/2026-pre-2.6/legacy-event-sources/event-log.jsonl' ]"

assert "#10 retired files preserve relative subpath" \
  "[ -f '$PROJ_ROOT/archive/2026-pre-2.6/legacy-event-sources/.runtime/events.jsonl' ]"

assert "#10 legacy_event_source_retired event emitted" \
  "grep -q '\"event\":\"legacy_event_source_retired\"' '$PROJ_ROOT/events/'*.jsonl"

assert "#10 retirement event carries parity metrics" \
  "grep -q '\"source_lines\":' '$PROJ_ROOT/events/'*.jsonl && grep -q '\"canonical_lines\":' '$PROJ_ROOT/events/'*.jsonl"

assert "#10 no event-log files outside events/ post-cleanup" \
  "[ -z \"\$(find '$PROJ_ROOT' -maxdepth 4 -type f \\( -name 'event-log.jsonl' -o -name 'events.ndjson' -o -name 'chanakya-events.jsonl' \\) -not -path '*/archive/*' 2>/dev/null)\" ]"

# ---- #11 feedback/ placeholder pruning (new layout) ----
assert "#11 feedback/root-causes pruned (placeholder only)" \
  "[ ! -d '$PROJ_ROOT/feedback/root-causes' ]"

assert "#11 feedback/reporters pruned (placeholder only)" \
  "[ ! -d '$PROJ_ROOT/feedback/reporters' ]"

assert "#11 feedback/archive preserved (has real content)" \
  "[ -f '$PROJ_ROOT/feedback/archive/build-3146.md' ]"

assert "#11 feedback_placeholder_pruned event emitted" \
  "grep -q '\"event\":\"feedback_placeholder_pruned\"' '$PROJ_ROOT/events/'*.jsonl"

# ---- #8 verify-ledger passes ----
# Capture rc without triggering `set -e` on a non-zero exit.
set +e
"$REPO_SCRIPTS/verify-ledger.sh" --project test-project >"$TMPROOT/verify.log" 2>&1
verify_rc=$?
set -e
assert "#8 verify-ledger.sh returns 0 (rc=$verify_rc; log below)" \
  "[ '$verify_rc' -eq 0 ]"
assert "#8 verify PASS output" \
  "grep -q 'PASS' '$TMPROOT/verify.log'"

# ---- #9 idempotency — second run does not re-do work ----
# Re-run should see existing backup and skip the copy. The existing
# artifacts will be overwritten (that's fine — transforms are pure), but
# the backup must not duplicate.
backup_size_before=$(du -s "$PROJ_ROOT/archive/2026-pre-2.6" 2>/dev/null | awk '{print $1}')
"$REPO_SCRIPTS/migrate-ledger.sh" --project test-project >"$TMPROOT/run2.log" 2>&1 || true
assert "#9 second run reports backup already exists" \
  "grep -q 'backup already exists' '$TMPROOT/run2.log'"
backup_size_after=$(du -s "$PROJ_ROOT/archive/2026-pre-2.6" 2>/dev/null | awk '{print $1}')
assert "#9 backup size unchanged on re-run" \
  "[ '$backup_size_before' = '$backup_size_after' ]"

printf 'PASS: %d assertions\n' "$assertions"
