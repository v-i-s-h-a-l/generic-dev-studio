#!/usr/bin/env bash
# GitHub issue staleness triage for the studio PM surface.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

REPO="${STUDIO_STALENESS_REPO:-v-i-s-h-a-l/generic-dev-studio}"
STALE_DAYS="${STUDIO_STALE_DAYS:-30}"
ESCALATE_DAYS="${STUDIO_ESCALATE_DAYS:-60}"
ARCHIVE_DAYS="${STUDIO_ARCHIVE_DAYS:-90}"
LIMIT="${STUDIO_STALENESS_LIMIT:-200}"
STALE_LABEL="${STUDIO_STALE_LABEL:-stale}"
ESCALATE_LABEL="${STUDIO_STALE_ESCALATE_LABEL:-stale:escalated}"
ARCHIVE_LABEL="${STUDIO_STALE_ARCHIVE_LABEL:-stale:archive-candidate}"
EXCLUDE_LABELS="${STUDIO_STALENESS_EXCLUDE_LABELS:-blocked,urgent,wontfix,duplicate,parking-lot}"
INPUT_FILE=""
APPLY=0
JSON_ONLY=0
NOW_EPOCH="${STUDIO_STALENESS_NOW_EPOCH:-}"

usage() {
  cat <<'USAGE'
usage: scripts/studio-staleness-triage.sh [options]

Options:
  --repo owner/repo        GitHub repository. Default: v-i-s-h-a-l/generic-dev-studio
  --stale-days N          Add stale label after N inactive days. Default: 30
  --escalate-days N       Add escalation label after N inactive days. Default: 60
  --archive-days N        Add archive-candidate label after N inactive days. Default: 90
  --limit N               Max open issues to inspect from GitHub. Default: 200
  --exclude-labels csv    Labels that opt an issue out of staleness triage.
  --input file            Read GitHub issue-list JSON from a file instead of gh.
  --json                  Print only the machine-readable triage plan.
  --apply | --post        Create labels, apply label changes, and post idempotent comments.
  --dry-run               Force preview-only behavior. This is the default.
  --help                  Show this help.

Environment mirrors the long options with STUDIO_STALE_DAYS,
STUDIO_ESCALATE_DAYS, STUDIO_ARCHIVE_DAYS, and STUDIO_STALENESS_* names.
USAGE
}

die() {
  printf 'studio-staleness-triage: %s\n' "$*" >&2
  exit 2
}

require_int() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*) die "$name must be a non-negative integer (got $value)" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo requires owner/repo}"; shift 2 ;;
    --stale-days) STALE_DAYS="${2:?--stale-days requires N}"; shift 2 ;;
    --escalate-days) ESCALATE_DAYS="${2:?--escalate-days requires N}"; shift 2 ;;
    --archive-days) ARCHIVE_DAYS="${2:?--archive-days requires N}"; shift 2 ;;
    --limit) LIMIT="${2:?--limit requires N}"; shift 2 ;;
    --exclude-labels) EXCLUDE_LABELS="${2:?--exclude-labels requires csv}"; shift 2 ;;
    --input) INPUT_FILE="${2:?--input requires file}"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    --apply|--post) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown arg $1" ;;
  esac
done

require_int "--stale-days" "$STALE_DAYS"
require_int "--escalate-days" "$ESCALATE_DAYS"
require_int "--archive-days" "$ARCHIVE_DAYS"
require_int "--limit" "$LIMIT"

[ "$STALE_DAYS" -le "$ESCALATE_DAYS" ] || die "--stale-days must be <= --escalate-days"
[ "$ESCALATE_DAYS" -le "$ARCHIVE_DAYS" ] || die "--escalate-days must be <= --archive-days"

command -v jq >/dev/null 2>&1 || die "jq is required on PATH"
if [ -z "$INPUT_FILE" ]; then
  command -v gh >/dev/null 2>&1 || die "gh is required on PATH when --input is not used"
fi

if [ -z "$NOW_EPOCH" ]; then
  NOW_EPOCH=$(date +%s)
fi
require_int "STUDIO_STALENESS_NOW_EPOCH" "$NOW_EPOCH"

fetch_issues_json() {
  if [ -n "$INPUT_FILE" ]; then
    [ -f "$INPUT_FILE" ] || die "input file not found: $INPUT_FILE"
    cat "$INPUT_FILE"
    return 0
  fi

  with_login_home_for_github gh issue list \
    --repo "$REPO" \
    --state open \
    --limit "$LIMIT" \
    --json number,title,url,state,createdAt,updatedAt,labels,comments,author,assignees,milestone
}

build_plan() {
  jq \
    --arg repo "$REPO" \
    --arg stale_label "$STALE_LABEL" \
    --arg escalate_label "$ESCALATE_LABEL" \
    --arg archive_label "$ARCHIVE_LABEL" \
    --arg exclude_labels "$EXCLUDE_LABELS" \
    --argjson now "$NOW_EPOCH" \
    --argjson stale_days "$STALE_DAYS" \
    --argjson escalate_days "$ESCALATE_DAYS" \
    --argjson archive_days "$ARCHIVE_DAYS" '
      def label_names($issue):
        [ $issue.labels[]? | if type == "object" then (.name // empty) else . end ];
      def has_label($issue; $name): (label_names($issue) | index($name)) != null;
      def excluded($issue; $excluded): any(label_names($issue)[]?; . as $label | ($excluded | index($label)) != null);
      def iso_epoch($value): (($value // "1970-01-01T00:00:00Z") | fromdateiso8601);
      def staleish($issue): has_label($issue; $stale_label) or has_label($issue; $escalate_label) or has_label($issue; $archive_label);
      def non_automation_comment_epochs($issue):
        [ $issue.comments[]?
          | select(((.body // "") | contains("studio-staleness-triage")) | not)
          | iso_epoch(.createdAt)
        ];
      def activity_epoch($issue):
        if staleish($issue) then
          ([ iso_epoch($issue.createdAt) ] + non_automation_comment_epochs($issue) | max)
        else
          iso_epoch($issue.updatedAt // $issue.createdAt)
        end;
      def inactive_days:
        (. as $issue
        | (((($now - activity_epoch($issue)) / 86400) | floor) as $days
          | if $days < 0 then 0 else $days end));
      def remove_staleish:
        . as $issue
        | [ $stale_label, $escalate_label, $archive_label ] | map(select(has_label($issue; .) == true));
      def comment($tier; $days; $threshold):
        {
          marker: ("<!-- studio-staleness-triage:" + $tier + ":issue-" + (.number | tostring) + " -->"),
          body: ("<!-- studio-staleness-triage:" + $tier + ":issue-" + (.number | tostring) + " -->\nStaleness triage: this issue has had no recorded activity for " + ($days | tostring) + " days (threshold: " + ($threshold | tostring) + " days). Please move it forward, re-scope it, or archive it if it is no longer relevant.")
        };
      ($exclude_labels | split(",") | map(select(length > 0))) as $excluded
      | map(select(((.state // "OPEN") | ascii_downcase) == "open"))
      | map(
          . as $issue
          | (inactive_days) as $days
          | {
              number,
              title,
              url,
              inactive_days: $days,
              labels: label_names($issue),
              add_labels: [],
              remove_labels: [],
              comment: null,
              reason: "fresh"
            }
          | if excluded($issue; $excluded) then
              .reason = "excluded"
            elif $days >= $archive_days then
              .add_labels = ([ $stale_label, $escalate_label, $archive_label ] | map(select(has_label($issue; .) | not)))
              | .reason = "archive_candidate"
              | .comment = ($issue | comment("archive-candidate"; $days; $archive_days))
            elif $days >= $escalate_days then
              .add_labels = ([ $stale_label, $escalate_label ] | map(select(has_label($issue; .) | not)))
              | .remove_labels = (if has_label($issue; $archive_label) then [ $archive_label ] else [] end)
              | .reason = "escalate"
              | .comment = ($issue | comment("escalated"; $days; $escalate_days))
            elif $days >= $stale_days then
              .add_labels = ([ $stale_label ] | map(select(has_label($issue; .) | not)))
              | .remove_labels = (if has_label($issue; $escalate_label) or has_label($issue; $archive_label) then
                  ([ $escalate_label, $archive_label ] | map(select(has_label($issue; .))))
                else [] end)
              | .reason = "stale"
            else
              .remove_labels = ($issue | remove_staleish)
              | .reason = "fresh"
            end
        )
      | {
          schema_version: 1,
          kind: "studio_staleness_triage_plan",
          repo: $repo,
          generated_at_epoch: $now,
          thresholds: {
            stale_days: $stale_days,
            escalate_days: $escalate_days,
            archive_days: $archive_days
          },
          labels: {
            stale: $stale_label,
            escalate: $escalate_label,
            archive_candidate: $archive_label,
            excluded: $excluded
          },
          counts: {
            inspected: length,
            stale: (map(select(.reason == "stale")) | length),
            escalate: (map(select(.reason == "escalate")) | length),
            archive_candidate: (map(select(.reason == "archive_candidate")) | length),
            fresh: (map(select(.reason == "fresh")) | length),
            excluded: (map(select(.reason == "excluded")) | length),
            mutating_issue_count: (map(select(((.add_labels | length) + (.remove_labels | length) + (if .comment == null then 0 else 1 end)) > 0)) | length)
          },
          issues: .
        }
    '
}

label_exists() {
  local label="$1"
  with_login_home_for_github gh label list --repo "$REPO" --limit 500 --json name \
    --jq "map(.name) | index(\"$label\") != null" | grep -qx true
}

ensure_label() {
  local label="$1" color="$2" description="$3"
  if label_exists "$label"; then
    return 0
  fi
  with_login_home_for_github gh label create "$label" \
    --repo "$REPO" \
    --color "$color" \
    --description "$description"
}

comment_already_posted() {
  local issue="$1" marker="$2"
  with_login_home_for_github gh issue view "$issue" --repo "$REPO" --json comments \
    --jq '.comments[].body' | grep -Fqx "$marker"
}

apply_plan() {
  local plan_file="$1"

  ensure_label "$STALE_LABEL" "c5def5" "Inactive issue; needs owner review."
  ensure_label "$ESCALATE_LABEL" "fbca04" "Inactive past escalation threshold."
  ensure_label "$ARCHIVE_LABEL" "d93f0b" "Inactive past archive-candidate threshold."

  jq -c '.issues[] | select(((.add_labels | length) + (.remove_labels | length) + (if .comment == null then 0 else 1 end)) > 0)' "$plan_file" |
    while IFS= read -r issue_json; do
      local issue labels marker body
      issue=$(printf '%s\n' "$issue_json" | jq -r '.number')

      labels=$(printf '%s\n' "$issue_json" | jq -r '.add_labels[]?')
      if [ -n "$labels" ]; then
        while IFS= read -r label; do
          [ -n "$label" ] || continue
          with_login_home_for_github gh issue edit "$issue" --repo "$REPO" --add-label "$label"
        done <<EOF
$labels
EOF
      fi

      labels=$(printf '%s\n' "$issue_json" | jq -r '.remove_labels[]?')
      if [ -n "$labels" ]; then
        while IFS= read -r label; do
          [ -n "$label" ] || continue
          with_login_home_for_github gh issue edit "$issue" --repo "$REPO" --remove-label "$label"
        done <<EOF
$labels
EOF
      fi

      marker=$(printf '%s\n' "$issue_json" | jq -r '.comment.marker // empty')
      if [ -n "$marker" ] && ! comment_already_posted "$issue" "$marker"; then
        body=$(printf '%s\n' "$issue_json" | jq -r '.comment.body')
        with_login_home_for_github gh issue comment "$issue" --repo "$REPO" --body "$body"
      fi
    done
}

tmp_plan=$(mktemp -t studio-staleness-triage.XXXXXX)
trap 'rm -f "$tmp_plan"' EXIT

fetch_issues_json | build_plan > "$tmp_plan"

if [ "$APPLY" -eq 1 ]; then
  apply_plan "$tmp_plan"
fi

if [ "$JSON_ONLY" -eq 1 ]; then
  cat "$tmp_plan"
else
  jq -r '
    "staleness_triage: inspected=\(.counts.inspected) stale=\(.counts.stale) escalate=\(.counts.escalate) archive_candidate=\(.counts.archive_candidate) fresh=\(.counts.fresh) excluded=\(.counts.excluded) mutations=\(.counts.mutating_issue_count)",
    (.issues[] | select(((.add_labels | length) + (.remove_labels | length) + (if .comment == null then 0 else 1 end)) > 0)
      | "#\(.number) \(.reason) inactive=\(.inactive_days)d add=[\(.add_labels | join(","))] remove=[\(.remove_labels | join(","))]")
  ' "$tmp_plan"
fi
