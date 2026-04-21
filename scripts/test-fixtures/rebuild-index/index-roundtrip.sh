#!/usr/bin/env bash
# index-roundtrip.sh — fixture test for scripts/rebuild-index.sh and
# scripts/query-plans.sh. Builds a synthetic plans/ tree with one of each
# kind, rebuilds the index, asserts structure, then exercises query-plans
# filters.

set -eu
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_SCRIPTS=$(cd "$SCRIPT_DIR/../.." && pwd)

TMPROOT=$(mktemp -d -t index-fixture.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PROJ_ROOT="$TMPROOT/project"
mkdir -p "$PROJ_ROOT/plans"/{tasks,briefs,debriefs,reviews,rounds,releases,feedback,crashes}

export ACHILLES_PROJECT="index-fixture"
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

# UUID stand-ins. Prefixes keep the asserts readable.
T_ID="t1111111-1111-7111-8111-111111111111"
B_ID="b2222222-2222-7222-8222-222222222222"
D_ID="d3333333-3333-7333-8333-333333333333"
R_ID="r4444444-4444-7444-8444-444444444444"
RD_ID="rd555555-5555-7555-8555-555555555555"
RL_ID="rl666666-6666-7666-8666-666666666666"
F_ID="f7777777-7777-7777-8777-777777777777"
C_ID="c8888888-8888-7888-8888-888888888888"

# ---- Synthetic artifacts ----

cat > "$PROJ_ROOT/plans/tasks/$T_ID.yaml" <<EOF
schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: $T_ID
title: "Sample task"
state: verified
size: m
created_at: 2026-04-22T10:00:00Z
updated_at: 2026-04-22T12:00:00Z
links:
  brief: $B_ID
  debrief: $D_ID
  reviews:
    - $R_ID
  release: $RL_ID
  feedback:
    - $F_ID
history: []
EOF

cat > "$PROJ_ROOT/plans/briefs/$B_ID.yaml" <<EOF
schema_version: {name: brief, version: 3.1.0, min_reader: 3.0.0, deprecated_at: null}
id: $B_ID
task_id: $T_ID
type: impl
size: m
state: debriefed
created_at: 2026-04-22T10:00:00Z
updated_at: 2026-04-22T10:00:00Z
figma: null
reads: []
writes: []
acceptance: []
testability: []
rework_of: null
body: |
  sample brief body
EOF

cat > "$PROJ_ROOT/plans/debriefs/$D_ID.yaml" <<EOF
schema_version: {name: debrief, version: 2.0.0, min_reader: 2.0.0, deprecated_at: null}
id: $D_ID
task_id: $T_ID
brief_id: $B_ID
mode: task
completed_at: 2026-04-22T12:00:00Z
EOF

cat > "$PROJ_ROOT/plans/reviews/$R_ID.yaml" <<EOF
schema_version: {name: review, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: $R_ID
subject:
  kind: task
  id: $T_ID
reviewer: argus
state: approved
verdict: approved
requested_at: 2026-04-22T11:00:00Z
completed_at: 2026-04-22T11:30:00Z
findings: []
checks_run: []
scope: {diff_size: 50, file_count: 3, caps_triggered: []}
notes: null
EOF

cat > "$PROJ_ROOT/plans/rounds/$RD_ID.yaml" <<EOF
schema_version: {name: round, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: $RD_ID
round_number: 1
state: closed
scope: new
generated_at: 2026-04-22T10:00:00Z
closed_at: 2026-04-22T14:00:00Z
tasks:
  - $T_ID
reviews: []
cases: []
summary: {cases_total: 0, pass: 0, fail: 0, pending: 0}
EOF

cat > "$PROJ_ROOT/plans/releases/$RL_ID.yaml" <<EOF
schema_version: {name: release, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: $RL_ID
channel: testflight
state: released
build_number: 3047
version: "1.12.0"
tag: "TF-3047"
commit_sha: "a1b2c3d4e5f6"
submitted_at: 2026-04-22T14:00:00Z
tasks:
  - $T_ID
reviews: []
asc_metadata: null
slack: null
EOF

cat > "$PROJ_ROOT/plans/feedback/$F_ID.yaml" <<EOF
schema_version: {name: feedback, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: $F_ID
state: resolved
source: slack-thread
reporter: "U0ABCDEF"
source_metadata: {}
ingested_at: 2026-04-22T09:00:00Z
subject: "Sample feedback"
labels: []
linked_tasks:
  - $T_ID
linked_crashes: []
root_cause_id: null
attachments: []
resolved_by: null
resolved_at: null
notes: null
body: |
  sample feedback
EOF

cat > "$PROJ_ROOT/plans/crashes/$C_ID.yaml" <<EOF
schema_version: {name: crash, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
id: $C_ID
state: linked
crashlytics_issue_id: "issue-1"
issue_title: "SIGSEGV"
fingerprint_sha256: "abc"
first_seen_at: 2026-04-20T08:00:00Z
last_seen_at: 2026-04-22T14:00:00Z
builds_affected: []
versions_affected: []
occurrence_count: 5
users_affected: 2
sample_stack_trace: ""
device_breakdown: []
os_breakdown: []
linked_tasks:
  - $T_ID
linked_feedback:
  - $F_ID
fixed_in: {release_id: null, commit_sha: null, verified_no_regression_for_builds: []}
notes: null
EOF

# ---- Rebuild index ----

"$REPO_SCRIPTS/rebuild-index.sh" --project index-fixture >"$TMPROOT/rebuild.log" 2>&1 \
  || fail "rebuild-index.sh failed. Log:\n$(cat "$TMPROOT/rebuild.log")"

INDEX="$PROJ_ROOT/plans/index.yaml"

assert "#1 index file written" \
  "[ -f '$INDEX' ]"

assert "#2 index header carries schema_version" \
  "grep -q 'schema_version: {name: plans-index, version: 1.0.0' '$INDEX'"

assert "#3 index lists the task" \
  "grep -q 'id: $T_ID' '$INDEX'"

assert "#3 index records task state" \
  "grep -q 'state: verified' '$INDEX'"

assert "#3 index records task→brief link" \
  "grep -q 'brief: $B_ID' '$INDEX'"

assert "#3 index records task→reviews list" \
  "grep -q 'reviews: \\[$R_ID\\]' '$INDEX'"

assert "#4 index lists the brief with task_id back-ref" \
  "awk '/^briefs:/{f=1;next} f && /^[a-z]/{exit} f' '$INDEX' | grep -q 'task_id: $T_ID'"

assert "#5 index lists the debrief with both task_id and brief_id" \
  "awk '/^debriefs:/{f=1;next} f && /^[a-z]/{exit} f' '$INDEX' | grep -q 'task_id: $T_ID' && awk '/^debriefs:/{f=1;next} f && /^[a-z]/{exit} f' '$INDEX' | grep -q 'brief_id: $B_ID'"

assert "#6 index lists the review with inline subject" \
  "awk '/^reviews:/{f=1;next} f && /^[a-z]/{exit} f' '$INDEX' | grep -q 'subject: {kind: task, id: $T_ID}'"

assert "#7 index lists the round with tasks array" \
  "awk '/^rounds:/{f=1;next} f && /^[a-z]/{exit} f' '$INDEX' | grep -q 'tasks: \\[$T_ID\\]'"

assert "#8 index lists the release with channel/tag" \
  "awk '/^releases:/{f=1;next} f && /^[a-z]/{exit} f' '$INDEX' | grep -q 'channel: testflight' && awk '/^releases:/{f=1;next} f && /^[a-z]/{exit} f' '$INDEX' | grep -q 'tag: TF-3047'"

assert "#9 index lists the feedback with linked_tasks" \
  "awk '/^feedback:/{f=1;next} f && /^[a-z]/{exit} f' '$INDEX' | grep -q 'linked_tasks: \\[$T_ID\\]'"

assert "#10 index lists the crash with linked_tasks + linked_feedback" \
  "awk '/^crashes:/{f=1;next} f && /^[a-z]/{exit} f' '$INDEX' | grep -q 'linked_tasks: \\[$T_ID\\]' && awk '/^crashes:/{f=1;next} f && /^[a-z]/{exit} f' '$INDEX' | grep -q 'linked_feedback: \\[$F_ID\\]'"

# ---- Validate: rerunning with --validate on a clean tree exits 0 ----
set +e
"$REPO_SCRIPTS/rebuild-index.sh" --project index-fixture --validate >/dev/null 2>&1
validate_rc=$?
set -e
assert "#11 --validate returns 0 when index is current" \
  "[ '$validate_rc' -eq 0 ]"

# ---- Drift detection: modify an artifact, --validate must exit 1 ----
echo '# drift' >> "$PROJ_ROOT/plans/tasks/$T_ID.yaml"
# Actually drift is only visible if the change affects a field the index
# captures. Change state instead.
sed -i.bak 's/state: verified/state: archived/' "$PROJ_ROOT/plans/tasks/$T_ID.yaml"
rm -f "$PROJ_ROOT/plans/tasks/$T_ID.yaml.bak"

set +e
"$REPO_SCRIPTS/rebuild-index.sh" --project index-fixture --validate >/dev/null 2>&1
drift_rc=$?
set -e
assert "#12 --validate returns 1 after artifact edit (drift)" \
  "[ '$drift_rc' -eq 1 ]"

# Rebuild to restore clean state.
"$REPO_SCRIPTS/rebuild-index.sh" --project index-fixture >/dev/null 2>&1

# ---- query-plans.sh: basic filter ----
if command -v yq >/dev/null 2>&1; then
  out=$("$REPO_SCRIPTS/query-plans.sh" --project index-fixture --kind=tasks --state=archived 2>&1 || true)
  assert "#13 query-plans --kind=tasks --state=archived returns the task" \
    "printf '%s' '$out' | grep -q '$T_ID'"

  out2=$("$REPO_SCRIPTS/query-plans.sh" --project index-fixture --kind=releases --channel=testflight 2>&1 || true)
  assert "#14 query-plans --kind=releases --channel=testflight returns the release" \
    "printf '%s' '$out2' | grep -q '$RL_ID'"
else
  printf 'skip: yq not installed — skipping query-plans.sh assertions\n'
fi

printf 'PASS: %d assertions\n' "$assertions"
