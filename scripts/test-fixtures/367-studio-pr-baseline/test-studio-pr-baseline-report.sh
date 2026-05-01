#!/usr/bin/env bash
# Verifies studio-pr-baseline-report separates implementation vs PR-open time,
# generated churn, GitHub gate signals, and public-safe trend output.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-pr-baseline.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf 'v-i-s-h-a-l/generic-dev-studio\n'
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  printf '366\n367\n'
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
  pr="$3"
  case "$pr" in
    366)
      cat <<'EOF'
scripts/forge-safety.sh
docs-surface.json
_shared/schemas/capability-manifest.json
README.md
EOF
      ;;
    367)
      cat <<'EOF'
scripts/studio-pr-baseline-report.sh
scripts/test-fixtures/367-studio-pr-baseline/test-studio-pr-baseline-report.sh
README.md
EOF
      ;;
  esac
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  pr="$3"
  case "$pr" in
    366)
      cat <<'JSON'
{
  "number": 366,
  "title": "routine Forge safety",
  "createdAt": "2026-05-01T10:38:56Z",
  "updatedAt": "2026-05-01T10:40:16Z",
  "mergedAt": "2026-05-01T10:40:16Z",
  "additions": 457,
  "deletions": 78,
  "changedFiles": 22,
  "baseRefName": "main",
  "headRefName": "feature/forge-safety",
  "body": "Closes #364\nCloses #365",
  "labels": [{"name":"track:forge-reliability"}],
  "closingIssuesReferences": [{"number":364},{"number":365}],
  "reviews": [],
  "statusCheckRollup": [],
  "mergeCommit": {"oid":"merge366"},
  "commits": [
    {"oid":"a1","committedDate":"2026-05-01T10:00:00Z","messageHeadline":"Implement Forge safety fix"},
    {"oid":"b2","committedDate":"2026-05-01T10:35:06Z","messageHeadline":"Expand scope for generated manifests"},
    {"oid":"c3","committedDate":"2026-05-01T10:38:24Z","messageHeadline":"Merge branch main and resolve generated manifest conflicts"}
  ]
}
JSON
      ;;
    367)
      cat <<'JSON'
{
  "number": 367,
  "title": "Track studio workflow performance baselines per PR",
  "createdAt": "2026-05-01T11:20:00Z",
  "updatedAt": "2026-05-01T11:28:00Z",
  "mergedAt": "2026-05-01T11:30:00Z",
  "additions": 210,
  "deletions": 5,
  "changedFiles": 3,
  "baseRefName": "main",
  "headRefName": "feature/field-telemetry-mvp",
  "body": "Closes #367",
  "labels": [{"name":"enhancement"}],
  "closingIssuesReferences": [{"number":367}],
  "reviews": [{"state":"APPROVED"}],
  "statusCheckRollup": [{"name":"lint"}],
  "mergeCommit": {"oid":"merge367"},
  "commits": [
    {"oid":"d1","committedDate":"2026-05-01T11:00:00Z","messageHeadline":"Add PR baseline report"}
  ]
}
JSON
      ;;
  esac
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/gh"

PATH="$BIN:$PATH"
export PATH

out="$TMPROOT/out"
"$ROOT/scripts/studio-pr-baseline-report.sh" --repo v-i-s-h-a-l/generic-dev-studio 366 > "$out"

grep -q 'Studio PR workflow baseline: #366' "$out" || {
  printf 'missing PR header\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'implementation to PR open: 38m 56s' "$out" || {
  printf 'implementation span mismatch\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'PR open to merge: 1m 20s' "$out" || {
  printf 'PR-open span mismatch\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'changed files: 22' "$out" || {
  printf 'changed files missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'additions/deletions: +457 / -78' "$out" || {
  printf 'line churn missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'issues closed: 2' "$out" || {
  printf 'issue count missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'generated-file churn: 2' "$out" || {
  printf 'generated churn missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'generated manifest conflict: possible_from_merge_or_conflict_commit' "$out" || {
  printf 'generated conflict inference missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'implementation/scope work dominated elapsed time' "$out" || {
  printf 'phase interpretation missing\n' >&2
  cat "$out" >&2
  exit 1
}
grep -q 'Privacy note' "$out" || {
  printf 'privacy note missing\n' >&2
  cat "$out" >&2
  exit 1
}

out367="$TMPROOT/out367"
"$ROOT/scripts/studio-pr-baseline-report.sh" --repo v-i-s-h-a-l/generic-dev-studio 367 > "$out367"
grep -q 'lint/test commands from checks: lint' "$out367" || {
  printf 'lint/test command extraction missing\n' >&2
  cat "$out367" >&2
  exit 1
}

json="$TMPROOT/out.json"
"$ROOT/scripts/studio-pr-baseline-report.sh" --repo v-i-s-h-a-l/generic-dev-studio 366 --json > "$json"
jq -e '.[0].phase_seconds.implementation_to_pr_open == 2336' "$json" >/dev/null || {
  printf 'json implementation seconds mismatch\n' >&2
  cat "$json" >&2
  exit 1
}
jq -e '.[0].phase_seconds.pr_open_to_merge == 80' "$json" >/dev/null || {
  printf 'json PR-open seconds mismatch\n' >&2
  cat "$json" >&2
  exit 1
}

trend="$TMPROOT/trend"
"$ROOT/scripts/studio-pr-baseline-report.sh" --repo v-i-s-h-a-l/generic-dev-studio --recent 2 > "$trend"
grep -q 'Trend summary by task class' "$trend" || {
  printf 'trend summary missing\n' >&2
  cat "$trend" >&2
  exit 1
}
grep -Eq '^track:forge-reliability[[:space:]]+1[[:space:]]+38m 56s[[:space:]]+1m 20s' "$trend" || {
  printf 'forge reliability trend row missing\n' >&2
  cat "$trend" >&2
  exit 1
}
grep -Eq '^enhancement[[:space:]]+1[[:space:]]+20m 0s[[:space:]]+10m 0s' "$trend" || {
  printf 'enhancement trend row missing\n' >&2
  cat "$trend" >&2
  exit 1
}

printf 'PASS: studio PR baseline report\n'
