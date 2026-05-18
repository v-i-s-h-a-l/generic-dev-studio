#!/usr/bin/env bash
# bug-reopen-iteration-report.sh — iteration-based bug reopen metric for #549.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# shellcheck source=scripts/lib-artifact-cleanup.sh
. "$SCRIPT_DIR/lib-artifact-cleanup.sh"

REPO=""
CUTOVER="2026-05-03T23:37:02Z"
COHORT_SIZE=20
EVENTS_JSON=""
OUTPUT_JSON=0
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/bug-reopen-iteration-report.sh --repo owner/repo [--cutover ISO] [--cohort-size N] [--json]
  scripts/bug-reopen-iteration-report.sh --events-json events.json [--cutover ISO] [--cohort-size N] [--json]

Computes the #549 iteration-based bug-reopen metric. A closure iteration is one
`closed` event on a bug issue. A closure is counted as reopened when the same
issue receives a later `reopened` event before its next closure.
EOF
  exit 2
}

fail() {
  printf 'bug-reopen-iteration-report: %s\n' "$1" >&2
  exit "${2:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --cutover) CUTOVER="${2:?--cutover requires an ISO timestamp}"; shift 2 ;;
    --cutover=*) CUTOVER="${1#--cutover=}"; shift ;;
    --cohort-size) COHORT_SIZE="${2:?--cohort-size requires a number}"; shift 2 ;;
    --cohort-size=*) COHORT_SIZE="${1#--cohort-size=}"; shift ;;
    --events-json) EVENTS_JSON="${2:?--events-json requires a file}"; shift 2 ;;
    --events-json=*) EVENTS_JSON="${1#--events-json=}"; shift ;;
    --now) NOW="${2:?--now requires an ISO timestamp}"; shift 2 ;;
    --now=*) NOW="${1#--now=}"; shift ;;
    --json) OUTPUT_JSON=1; shift ;;
    -h|--help) usage ;;
    *) fail "unknown argument: $1" 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq required" 2
case "$COHORT_SIZE" in
  ''|*[!0-9]*) fail "--cohort-size must be numeric: $COHORT_SIZE" 2 ;;
esac
[ "$COHORT_SIZE" -gt 0 ] || fail "--cohort-size must be greater than zero" 2
[ -n "$EVENTS_JSON" ] || [ -n "$REPO" ] || fail "provide --events-json or --repo" 2
[ -z "$EVENTS_JSON" ] || [ -r "$EVENTS_JSON" ] || fail "cannot read events JSON: $EVENTS_JSON" 2

TMPROOT=$(mktemp -d -t bug-reopen-iteration.XXXXXX); register_artifact tmpdir "$TMPROOT"
NORMALIZED="$TMPROOT/events.json"

if [ -n "$EVENTS_JSON" ]; then
  jq '
    def issue_number:
      .issue_number // .issue // .number // .issue.number // .issue_url
      | if type == "string" then capture("issues/(?<n>[0-9]+)").n? // . else . end
      | tonumber;
    [ .[]?
      | select((.event // .type // "") == "closed" or (.event // .type // "") == "reopened")
      | {
          issue_number: issue_number,
          event: (.event // .type),
          created_at: (.created_at // .timestamp)
        }
      | select(.issue_number != null and .created_at != null)
    ]
  ' "$EVENTS_JSON" > "$NORMALIZED"
else
  issues="$TMPROOT/issues.json"
  : > "$NORMALIZED"
  "$SCRIPT_DIR/studio-gh.sh" api --paginate "/repos/$REPO/issues?state=all&labels=bug&per_page=100" > "$issues"
  jq -r '.[].number' "$issues" | while IFS= read -r issue_number; do
    [ -n "$issue_number" ] || continue
    "$SCRIPT_DIR/studio-gh.sh" api --paginate "/repos/$REPO/issues/$issue_number/events?per_page=100" \
      | jq --argjson issue_number "$issue_number" '
          [ .[]?
            | select(.event == "closed" or .event == "reopened")
            | {issue_number: $issue_number, event, created_at}
          ]
        ' > "$TMPROOT/events-$issue_number.json"
  done
  jq -s 'add // []' "$TMPROOT"/events-*.json > "$NORMALIZED" 2>/dev/null || printf '[]\n' > "$NORMALIZED"
fi

REPORT="$TMPROOT/report.json"
jq -S \
  --arg cutover "$CUTOVER" \
  --arg now "$NOW" \
  --argjson cohort_size "$COHORT_SIZE" '
  def rate($reopened; $total):
    if $total == 0 then null else ($reopened / $total) end;
  def rounded:
    if . == null then null else ((. * 10000 | round) / 10000) end;
  def pct:
    if . == null then "n/a" else (((. * 10000 | round) / 100) | tostring) + "%" end;
  def closure_iterations:
    sort_by(.issue_number, .created_at)
    | group_by(.issue_number)
    | map(
        sort_by(.created_at) as $events
        | [range(0; $events | length) as $i
          | select($events[$i].event == "closed")
          | ($events[$i].created_at) as $closed_at
          | ([range($i + 1; $events | length) as $j
              | select($events[$j].event == "closed")
              | $events[$j].created_at][0] // $now) as $next_close_or_snapshot
          | {
              issue_number: $events[$i].issue_number,
              closed_at: $closed_at,
              boundary_at: $next_close_or_snapshot,
              reopened: (any($events[];
                .event == "reopened"
                and .created_at > $closed_at
                and .created_at < $next_close_or_snapshot
              ))
            }
        ]
      )
    | add // []
    | sort_by(.closed_at);
  def cohort_summary($items):
    {
      requested_size: $cohort_size,
      count: ($items | length),
      reopened_count: ([$items[] | select(.reopened == true)] | length),
      rate: (rate(([$items[] | select(.reopened == true)] | length); ($items | length)) | rounded),
      issue_iterations: $items
    };

  closure_iterations as $iterations
  | ([$iterations[] | select(.closed_at < $cutover)] | sort_by(.closed_at) | .[-$cohort_size:]) as $baseline_items
  | ([$iterations[] | select(.closed_at >= $cutover)] | sort_by(.closed_at) | .[:$cohort_size]) as $post_items
  | (cohort_summary($baseline_items)) as $baseline
  | (cohort_summary($post_items)) as $post
  | {
      schema_version: 1,
      kind: "bug-reopen-iteration-report",
      cutover: $cutover,
      generated_at: $now,
      cohort_size: $cohort_size,
      definition: {
        unit: "bug-fix closure iteration",
        numerator: "closure iterations whose issue later receives a reopened event before the next closure for that same issue or the comparison snapshot",
        baseline: "last N bug-fix closure iterations before cutover",
        post_cutover: "first N bug-fix closure iterations after cutover"
      },
      baseline: $baseline,
      post_cutover: $post,
      comparison: {
        cohorts_complete: (($baseline.count >= $cohort_size) and ($post.count >= $cohort_size)),
        baseline_rate: $baseline.rate,
        post_cutover_rate: $post.rate,
        reduction_fraction: (
          if ($baseline.rate == null or $baseline.rate == 0 or $post.rate == null)
          then null
          else ((($baseline.rate - $post.rate) / $baseline.rate) | rounded)
          end
        ),
        claim_supported: (
          (($baseline.count >= $cohort_size) and ($post.count >= $cohort_size))
          and ($baseline.rate != null and $baseline.rate > 0)
          and ($post.rate != null)
          and ((($baseline.rate - $post.rate) / $baseline.rate) >= 0.25)
        ),
        claim_note: (
          if (($baseline.count >= $cohort_size) and ($post.count >= $cohort_size)) | not
          then "Directional only: at least one cohort has fewer than requested closure iterations."
          elif ($baseline.rate == null or $baseline.rate == 0)
          then "No 25% reduction claim: baseline rate is zero or undefined."
          elif ((($baseline.rate - $post.rate) / $baseline.rate) >= 0.25)
          then "25% reduction claim is supported by complete cohorts."
          else "No 25% reduction claim: observed reduction is below threshold."
          end
        )
      }
    }
  ' "$NORMALIZED" > "$REPORT"

if [ "$OUTPUT_JSON" -eq 1 ]; then
  cat "$REPORT"
else
  jq -r '
    def pct:
      if . == null then "n/a" else (((. * 10000 | round) / 100) | tostring) + "%" end;
    "# Bug Reopen Iteration Report",
    "",
    "- Cutover: `" + .cutover + "`",
    "- Cohort size: `" + (.cohort_size | tostring) + "`",
    "- Baseline: `" + (.baseline.reopened_count | tostring) + "/" + (.baseline.count | tostring) + "` reopened (`" + (.baseline.rate | pct) + "`)",
    "- Post-A10: `" + (.post_cutover.reopened_count | tostring) + "/" + (.post_cutover.count | tostring) + "` reopened (`" + (.post_cutover.rate | pct) + "`)",
    "- Claim supported: `" + (.comparison.claim_supported | tostring) + "`",
    "- Note: " + .comparison.claim_note
  ' "$REPORT"
fi
