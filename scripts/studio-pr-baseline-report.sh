#!/usr/bin/env bash
# studio-pr-baseline-report.sh - report public-safe workflow baselines for studio PRs.
#
# Usage:
#   scripts/studio-pr-baseline-report.sh 366
#   scripts/studio-pr-baseline-report.sh --recent 10
#   scripts/studio-pr-baseline-report.sh --repo owner/repo 366 --json
#
# Uses GitHub PR metadata plus the public PR diff name list. Missing local-only
# spans, such as cleanup completion and hook duration, are reported as gaps.

set -euo pipefail
umask 022

REPO=""
RECENT=""
JSON_ONLY=0
PR_NUMBERS=()

usage() {
  sed -n '2,/^# Uses/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --repo) REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
    --recent=*) RECENT="${1#--recent=}"; shift ;;
    --recent) RECENT="${2:?--recent requires N}"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      printf 'studio-pr-baseline-report: unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
    *)
      PR_NUMBERS+=("$1")
      shift
      ;;
  esac
done

command -v gh >/dev/null 2>&1 || { printf 'studio-pr-baseline-report: gh required\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'studio-pr-baseline-report: jq required\n' >&2; exit 2; }

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || {
    printf 'studio-pr-baseline-report: could not resolve repo. Pass --repo owner/repo.\n' >&2
    exit 2
  }
fi

case "$RECENT" in
  "") ;;
  ''|*[!0-9]*)
    printf 'studio-pr-baseline-report: --recent must be a positive integer\n' >&2
    exit 2
    ;;
  0)
    printf 'studio-pr-baseline-report: --recent must be > 0\n' >&2
    exit 2
    ;;
esac

if [ -n "$RECENT" ]; then
  while IFS= read -r pr; do
    [ -n "$pr" ] && PR_NUMBERS+=("$pr")
  done < <(gh pr list --repo "$REPO" --state merged --limit "$RECENT" --json number --jq '.[].number')
fi

if [ "${#PR_NUMBERS[@]}" -eq 0 ]; then
  printf 'studio-pr-baseline-report: pass a PR number or --recent N\n' >&2
  usage
  exit 2
fi

workdir=$(mktemp -d -t studio-pr-baseline.XXXXXX)
trap 'rm -rf "$workdir"' EXIT
rows="$workdir/rows.jsonl"
: > "$rows"

collect_pr() {
  local pr="$1" pr_json diff_names
  pr_json=$(gh pr view "$pr" --repo "$REPO" \
    --json number,title,createdAt,updatedAt,mergedAt,additions,deletions,changedFiles,commits,closingIssuesReferences,reviews,statusCheckRollup,labels,body,baseRefName,headRefName,mergeCommit)

  diff_names=$(gh pr diff "$pr" --repo "$REPO" --name-only 2>/dev/null || true)

  jq -n --argjson pr "$pr_json" --arg files "$diff_names" --arg repo "$REPO" '
    def ts_epoch($v): if ($v // "") == "" then null else (try ($v | fromdateiso8601 | floor) catch null) end;
    def duration($start; $end):
      if ($start == null or $end == null) then null else ($end - $start) end;
    def generated_path:
      test("(^|/)(docs-surface[.]json|.*manifest.*[.](json|ya?ml))$") or
      test("(^|/)chanakya/snapshots/") or
      test("(^|/)_shared/schemas/capability-manifest[.]json$");
    def issue_refs:
      (($pr.closingIssuesReferences // []) | length) as $api_count
      | ([($pr.body // "") | scan("(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+")] | length) as $body_count
      | if $api_count > 0 then $api_count else $body_count end;
    def task_class:
      [($pr.labels // [])[].name
       | select(test("^(track:|theme/|type:|kind:|bug|enhancement|polish|roadmap)"))] as $labels
      | if ($labels | length) > 0 then $labels[0] else "unclassified" end;
    def commit_epoch($c): ts_epoch($c.committedDate // $c.authoredDate // "");
    def merge_like($c):
      (($c.messageHeadline // $c.message // "") | test("(?i)(merge|conflict|resolve)"));

    ($files | split("\n") | map(select(. != ""))) as $paths
    | [ $paths[] | select(generated_path) ] as $generated_paths
    | [($pr.commits // [])[] | commit_epoch(.)] as $commit_epochs_raw
    | ($commit_epochs_raw | map(select(. != null)) | min) as $first_commit_epoch
    | ($commit_epochs_raw | map(select(. != null)) | max) as $last_commit_epoch
    | ts_epoch($pr.createdAt) as $created_epoch
    | ts_epoch($pr.mergedAt) as $merged_epoch
    | [($pr.commits // [])[] | select(merge_like(.))] as $merge_like_commits
    | (($merge_like_commits | length) > 0 and ($generated_paths | length) > 0) as $generated_conflict_possible
    | {
        schema_version: 1,
        repo: $repo,
        pr: ($pr.number | tonumber),
        task_class: task_class,
        timestamps: {
          first_task_commit: (
            if $first_commit_epoch == null then null
            else ($first_commit_epoch | todateiso8601)
            end
          ),
          pr_created: ($pr.createdAt // null),
          last_branch_update: (
            if $last_commit_epoch == null then null
            else ($last_commit_epoch | todateiso8601)
            end
          ),
          merged: ($pr.mergedAt // null),
          local_cleanup_completed: null
        },
        phase_seconds: {
          implementation_to_pr_open: duration($first_commit_epoch; $created_epoch),
          pr_open_to_merge: duration($created_epoch; $merged_epoch),
          first_commit_to_merge: duration($first_commit_epoch; $merged_epoch),
          last_branch_update_to_merge: duration($last_commit_epoch; $merged_epoch),
          local_cleanup: null
        },
        size: {
          changed_files: (($pr.changedFiles // ($paths | length)) | tonumber),
          additions: (($pr.additions // 0) | tonumber),
          deletions: (($pr.deletions // 0) | tonumber),
          commit_count: (($pr.commits // []) | length),
          generated_file_churn_count: ($generated_paths | length),
          hand_authored_file_churn_count: ((($pr.changedFiles // ($paths | length)) | tonumber) - ($generated_paths | length)),
          issue_count_closed: issue_refs
        },
        gates: {
          checks_reported: (($pr.statusCheckRollup // []) | length),
          reviews_reported: (($pr.reviews // []) | length),
          lint_or_test_commands: [
            ($pr.statusCheckRollup // [])[]
            | (.name // .context // .workflowName // "")
            | select(test("(?i)(lint|test|check|build)"))
          ],
          hook_duration_s: null,
          warnings: null,
          errors: null,
          generated_manifest_conflict: (
            if $generated_conflict_possible then "possible_from_merge_or_conflict_commit"
            elif ($generated_paths | length) > 0 then "not_reported"
            else "not_applicable"
            end
          )
        },
        generated_churn: {
          changed_file_count: ($generated_paths | length),
          patterns: (
            if ($generated_paths | length) > 0
            then ["manifest_or_snapshot"]
            else []
            end
          )
        },
        telemetry_gaps: [
          (if ($first_commit_epoch == null) then "first_task_commit" else empty end),
          (if ($created_epoch == null) then "pr_created" else empty end),
          (if ($merged_epoch == null) then "merged" else empty end),
          "local_cleanup_completed",
          "hook_duration_s",
          "lint_or_test_commands",
          "warnings",
          "errors"
        ]
      }
  ' >> "$rows"
}

for pr in "${PR_NUMBERS[@]}"; do
  case "$pr" in
    ''|*[!0-9]*)
      printf 'studio-pr-baseline-report: PR must be numeric: %s\n' "$pr" >&2
      exit 2
      ;;
  esac
  collect_pr "$pr"
done

if [ "$JSON_ONLY" -eq 1 ]; then
  jq -s '.' "$rows"
  exit 0
fi

jq -rs '
  def fmt_duration:
    if . == null then "unavailable"
    else
      (. | tonumber | floor) as $s
      | if $s < 0 then "after PR open"
        elif $s < 60 then "\($s)s"
        elif $s < 3600 then "\(($s / 60) | floor)m \($s % 60)s"
        else "\(($s / 3600) | floor)h \((($s % 3600) / 60) | floor)m \($s % 60)s"
        end
    end;
  .[] |
  "Studio PR workflow baseline: #\(.pr) (\(.repo))",
  "Task class: \(.task_class)",
  "Timestamps:",
  "  first task commit: \(.timestamps.first_task_commit // "unavailable")",
  "  PR created: \(.timestamps.pr_created // "unavailable")",
  "  last branch update: \(.timestamps.last_branch_update // "unavailable")",
  "  merged: \(.timestamps.merged // "unavailable")",
  "  local cleanup completed: \(.timestamps.local_cleanup_completed // "unavailable")",
  "Phase timing:",
  "  implementation to PR open: \(.phase_seconds.implementation_to_pr_open | fmt_duration)",
  "  PR open to merge: \(.phase_seconds.pr_open_to_merge | fmt_duration)",
  "  first task commit to merge: \(.phase_seconds.first_commit_to_merge | fmt_duration)",
  "  last branch update to merge: \(.phase_seconds.last_branch_update_to_merge | fmt_duration)",
  "Size and churn:",
  "  changed files: \(.size.changed_files)",
  "  additions/deletions: +\(.size.additions) / -\(.size.deletions)",
  "  branch commits: \(.size.commit_count)",
  "  issues closed: \(.size.issue_count_closed)",
  "  generated-file churn: \(.size.generated_file_churn_count)",
  "  hand-authored churn: \(.size.hand_authored_file_churn_count)",
  "Gate signals:",
  "  checks reported by GitHub: \(.gates.checks_reported)",
  "  reviews reported by GitHub: \(.gates.reviews_reported)",
  "  lint/test commands from checks: \(if (.gates.lint_or_test_commands | length) > 0 then (.gates.lint_or_test_commands | join(", ")) else "unavailable" end)",
  "  hook duration: \(.gates.hook_duration_s // "unavailable")",
  "  warnings/errors: \(.gates.warnings // "unavailable") / \(.gates.errors // "unavailable")",
  "  generated manifest conflict: \(.gates.generated_manifest_conflict)",
  "Interpretation:",
  (if (.phase_seconds.implementation_to_pr_open != null and .phase_seconds.pr_open_to_merge != null and (.phase_seconds.implementation_to_pr_open > .phase_seconds.pr_open_to_merge))
   then "  implementation/scope work dominated elapsed time"
   elif (.phase_seconds.pr_open_to_merge != null)
   then "  PR merge/review phase dominated or matched elapsed time"
   else "  insufficient timestamps for phase dominance"
   end),
  (if (.size.generated_file_churn_count > 0)
   then "  generated churn is separated from hand-authored churn"
   else "  no generated-file churn detected from PR diff names"
   end),
  "Telemetry gaps: \((.telemetry_gaps | unique) | join(", "))",
  "Privacy note: report uses PR-level counts, labels, timestamps, and generated-file classes only; it does not print file paths or commit messages.",
  ""
' "$rows"

if [ "${#PR_NUMBERS[@]}" -gt 1 ]; then
  jq -rs '
    def avg($xs): if ($xs | length) == 0 then null else (($xs | add) / ($xs | length)) end;
    def fmt_duration:
      if . == null then "n/a"
      else
        (. | tonumber | floor) as $s
        | if $s < 60 then "\($s)s"
          elif $s < 3600 then "\(($s / 60) | floor)m \($s % 60)s"
          else "\(($s / 3600) | floor)h \((($s % 3600) / 60) | floor)m"
          end
      end;
    group_by(.task_class)
    | map({
        task_class: .[0].task_class,
        count: length,
        avg_impl: avg([.[].phase_seconds.implementation_to_pr_open | select(. != null)]),
        avg_pr_open: avg([.[].phase_seconds.pr_open_to_merge | select(. != null)]),
        avg_changed_files: avg([.[].size.changed_files]),
        avg_generated_files: avg([.[].size.generated_file_churn_count])
      })
    | "Trend summary by task class",
      "class count avg_impl_to_pr avg_pr_open_to_merge avg_files avg_generated",
      (.[] | "\(.task_class) \(.count) \(.avg_impl | fmt_duration) \(.avg_pr_open | fmt_duration) \((.avg_changed_files * 10 | round / 10)) \((.avg_generated_files * 10 | round / 10))")
  ' "$rows"
fi
