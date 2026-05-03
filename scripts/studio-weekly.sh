#!/usr/bin/env bash
# Weekly Studio PM digest from GitHub issue metadata.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# shellcheck source=scripts/lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

REPO=""
DAYS=7
TREND_WEEKS=4
ISSUE_TITLE="Weekly Studio Digest"
POST=0
PIN=1
JSON_ONLY=0

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' >&2
  cat >&2 <<'USAGE'

Usage:
  scripts/studio-weekly.sh [--repo owner/repo] [--days N] [--json]
  scripts/studio-weekly.sh --post [--repo owner/repo] [--issue-title TITLE]

Options:
  --post               Create/reuse the weekly summary issue, pin it, and append the digest as a comment.
  --issue-title TITLE  Summary issue title. Default: Weekly Studio Digest.
  --no-pin             Skip pinning. Intended for tests or dry infrastructure checks.
  --trend-weeks N      Number of weekly velocity buckets. Default: 4.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --repo) REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
    --days=*) DAYS="${1#--days=}"; shift ;;
    --days) DAYS="${2:?--days requires N}"; shift 2 ;;
    --trend-weeks=*) TREND_WEEKS="${1#--trend-weeks=}"; shift ;;
    --trend-weeks) TREND_WEEKS="${2:?--trend-weeks requires N}"; shift 2 ;;
    --issue-title=*) ISSUE_TITLE="${1#--issue-title=}"; shift ;;
    --issue-title) ISSUE_TITLE="${2:?--issue-title requires a value}"; shift 2 ;;
    --post) POST=1; shift ;;
    --no-pin) PIN=0; shift ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'studio-weekly: unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$DAYS" in
  ''|*[!0-9]*|0) printf 'studio-weekly: --days must be a positive integer\n' >&2; exit 2 ;;
esac

case "$TREND_WEEKS" in
  ''|*[!0-9]*|0) printf 'studio-weekly: --trend-weeks must be a positive integer\n' >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || { printf 'studio-weekly: gh required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'studio-weekly: jq required\n' >&2; exit 2; }

gh_cmd() {
  with_login_home_for_github gh "$@"
}

date_days_ago() {
  local days="$1"
  if date -u -v-"$days"d +%F >/dev/null 2>&1; then
    date -u -v-"$days"d +%F
  else
    date -u -d "$days days ago" +%F
  fi
}

if [ -z "$REPO" ]; then
  REPO=$(gh_cmd repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || {
    printf 'studio-weekly: could not resolve repo. Pass --repo owner/repo.\n' >&2
    exit 2
  }
fi

today=$(date -u +%F)
window_start=$(date_days_ago "$DAYS")
trend_days=$((TREND_WEEKS * 7))
trend_start=$(date_days_ago "$trend_days")

workdir=$(mktemp -d -t studio-weekly.XXXXXX)
trap 'rm -rf "$workdir"' EXIT

open_json="$workdir/open.json"
created_json="$workdir/created.json"
closed_json="$workdir/closed.json"
summary_json="$workdir/summary.json"
digest_md="$workdir/digest.md"

gh_cmd issue list --repo "$REPO" --state open --limit 1000 \
  --json number,title,url,createdAt,updatedAt,labels,milestone > "$open_json"

gh_cmd issue list --repo "$REPO" --state all --limit 1000 \
  --search "created:>=$window_start" \
  --json number,title,url,createdAt,state,labels > "$created_json"

gh_cmd issue list --repo "$REPO" --state closed --limit 1000 \
  --search "closed:>=$trend_start" \
  --json number,title,url,createdAt,closedAt,labels,milestone > "$closed_json"

jq -n \
  --slurpfile open "$open_json" \
  --slurpfile created "$created_json" \
  --slurpfile closed "$closed_json" \
  --arg repo "$REPO" \
  --arg today "$today" \
  --arg window_start "$window_start" \
  --arg trend_start "$trend_start" \
  --argjson days "$DAYS" \
  --argjson trend_weeks "$TREND_WEEKS" '
  def iso_start($d): "\($d)T00:00:00Z";
  def iso_after_window: select((.closedAt // "") >= iso_start($window_start));
  def age_days($now):
    (((($now + "T00:00:00Z") | fromdateiso8601) - (.createdAt | fromdateiso8601)) / 86400 | floor);
  def bucket($age):
    if $age <= 7 then "0-7d"
    elif $age <= 14 then "8-14d"
    elif $age <= 30 then "15-30d"
    elif $age <= 60 then "31-60d"
    else "61d+"
    end;
  def count_bucket($name):
    [($open[0] // [])[] | bucket(age_days($today)) | select(. == $name)] | length;
  def labels_for($issue):
    ($issue.labels // []) | map(.name // empty);
  def top_labels($issues):
    [ $issues[] | labels_for(.)[] ]
    | group_by(.)
    | map({name: .[0], count: length})
    | sort_by(-.count, .name)
    | .[:10];
  def week_start($n):
    ((($today + "T00:00:00Z") | fromdateiso8601) - (($trend_weeks - $n) * 7 * 86400))
    | strftime("%Y-%m-%d");
  def week_end($n):
    ((($today + "T00:00:00Z") | fromdateiso8601) - (($trend_weeks - $n - 1) * 7 * 86400))
    | strftime("%Y-%m-%d");
  def closed_in_range($start; $end):
    [($closed[0] // [])[] | select((.closedAt // "") >= iso_start($start) and (.closedAt // "") < iso_start($end))] | length;
  ($open[0] // []) as $open_issues
  | ($created[0] // []) as $created_issues
  | ($closed[0] // []) as $closed_issues
  | [range(0; $trend_weeks) as $i
      | (week_start($i)) as $start
      | (week_end($i)) as $end
      | {start: $start, end: $end, closed: closed_in_range($start; $end)}
    ] as $trend
  | {
      schema_version: 1,
      repo: $repo,
      generated_at: (now | todateiso8601),
      window: {start: $window_start, end: $today, days: $days},
      counts: {
        open_now: ($open_issues | length),
        opened: ($created_issues | length),
        closed: ([ $closed_issues[] | iso_after_window ] | length),
        net_change: (($created_issues | length) - ([ $closed_issues[] | iso_after_window ] | length))
      },
      age_histogram: [
        {bucket: "0-7d", count: count_bucket("0-7d")},
        {bucket: "8-14d", count: count_bucket("8-14d")},
        {bucket: "15-30d", count: count_bucket("15-30d")},
        {bucket: "31-60d", count: count_bucket("31-60d")},
        {bucket: "61d+", count: count_bucket("61d+")}
      ],
      open_label_distribution: top_labels($open_issues),
      closed_label_distribution: top_labels([ $closed_issues[] | iso_after_window ]),
      velocity_trend: $trend,
      aged_open: (
        [ $open_issues[]
          | . + {age_days: age_days($today)}
          | select(.age_days >= 30)
          | {number, title, url, age_days, labels: labels_for(.)}
        ]
        | sort_by(-.age_days, .number)
        | .[:10]
      ),
      recently_closed: (
        [ $closed_issues[]
          | iso_after_window
          | {number, title, url, closedAt, labels: labels_for(.)}
        ]
        | sort_by(.closedAt)
        | reverse
        | .[:10]
      )
    }
  ' > "$summary_json"

if [ "$JSON_ONLY" -eq 1 ]; then
  cat "$summary_json"
  printf '\n'
  exit 0
fi

jq -r '
  def signed: if . > 0 then "+\(.)" else "\(.)" end;
  def link_issue: "[#\(.number)](\(.url)) \(.title)";
  def label_list:
    if (.labels | length) == 0 then "unlabeled"
    else (.labels | join(", "))
    end;
  "# Weekly Studio Digest - \(.window.end) UTC",
  "",
  "Repo: `\(.repo)`",
  "Window: \(.window.start) through \(.window.end) UTC",
  "",
  "## Summary",
  "",
  "- Open issues now: \(.counts.open_now)",
  "- Opened this week: \(.counts.opened)",
  "- Closed this week: \(.counts.closed)",
  "- Net backlog change: \(.counts.net_change | signed)",
  "",
  "## Open Issue Age",
  "",
  (.age_histogram[] | "- \(.bucket): \(.count)"),
  "",
  "## Open Label Distribution",
  "",
  (if (.open_label_distribution | length) == 0 then "- No labels on open issues."
   else (.open_label_distribution[] | "- \(.name): \(.count)") end),
  "",
  "## Velocity Trend",
  "",
  (.velocity_trend[] | "- \(.start) to \(.end): \(.closed) closed"),
  "",
  "## Aged Open Issues",
  "",
  (if (.aged_open | length) == 0 then "- No open issues older than 30 days."
   else (.aged_open[] | "- \(link_issue) - \(.age_days)d old - \(label_list)") end),
  "",
  "## Recently Closed",
  "",
  (if (.recently_closed | length) == 0 then "- No issues closed in this window."
   else (.recently_closed[] | "- \(link_issue) - closed \(.closedAt[0:10]) - \(label_list)") end),
  "",
  "<!-- generated-by: scripts/studio-weekly.sh -->"
' "$summary_json" > "$digest_md"

if [ "$POST" -eq 0 ]; then
  cat "$digest_md"
  exit 0
fi

issue_row=$(gh_cmd issue list --repo "$REPO" --state all --limit 50 \
  --search "in:title \"$ISSUE_TITLE\"" \
  --json number,title,state \
  | jq -r --arg title "$ISSUE_TITLE" '.[] | select(.title == $title) | [.number, .state] | @tsv' \
  | head -1 || true)

if [ -z "$issue_row" ]; then
  issue_body="$workdir/issue-body.md"
  cat > "$issue_body" <<EOF
Pinned collection point for the automated weekly Studio PM digest.

The scheduled workflow appends a new digest comment every Monday.
EOF
  issue_url=$(gh_cmd issue create --repo "$REPO" --title "$ISSUE_TITLE" --body-file "$issue_body")
  issue_number="${issue_url##*/}"
  issue_state="OPEN"
else
  issue_number=$(printf '%s\n' "$issue_row" | awk -F '\t' '{print $1}')
  issue_state=$(printf '%s\n' "$issue_row" | awk -F '\t' '{print $2}')
fi

if [ "$issue_state" != "OPEN" ]; then
  gh_cmd issue reopen "$issue_number" --repo "$REPO" >/dev/null
fi

if [ "$PIN" -eq 1 ]; then
  gh_cmd issue pin "$issue_number" --repo "$REPO" >/dev/null
fi

gh_cmd issue comment "$issue_number" --repo "$REPO" --body-file "$digest_md" >/dev/null
printf 'studio-weekly: posted digest to %s#%s\n' "$REPO" "$issue_number"
