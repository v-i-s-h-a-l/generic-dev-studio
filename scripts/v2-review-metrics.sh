#!/usr/bin/env bash
# Emit and report Studio v2 review finding disposition metrics.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REGISTRY="$REPO_ROOT/core/v2/review/metrics.yaml"
SCHEMA="$REPO_ROOT/core/v2/schemas/review-finding-event.schema.json"

COMMAND="${1:-}"
[ -n "$COMMAND" ] && shift || true

RUNTIME_ROOT=""
PHASE_REF=""
REVIEW_REF=""
REVIEW_HOST=""
REVIEW_KIND=""
FINDING_ID=""
SEVERITY=""
DISPOSITION=""
SUMMARY=""
PREVENTED_DEFECT_REF=""
FOLLOW_UP_REF=""
SUPERSEDED_BY=""
OCCURRED_AT=""
FORMAT="json"
OUTPUT=""
QUIET=0

usage() {
  cat >&2 <<'USAGE'
usage:
  scripts/v2-review-metrics.sh emit --runtime-root <dir> --phase-ref <ref> --review-ref <ref> --review-host <id> --review-kind <plan|outcome|pr|pre-commit> --finding-id <id> --severity <severity> --disposition <accepted|rejected|disputed|superseded> --summary <text> [--prevented-defect-ref <ref>] [--follow-up-ref <ref>] [--superseded-by <id>] [--occurred-at <iso8601>] [--quiet]
  scripts/v2-review-metrics.sh report --runtime-root <dir> [--format json|markdown] [--output <file>]
USAGE
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

require_tools() {
  command -v jq >/dev/null 2>&1 || { printf 'v2-review-metrics: jq is required\n' >&2; exit 3; }
  command -v yq >/dev/null 2>&1 || { printf 'v2-review-metrics: yq is required\n' >&2; exit 3; }
  command -v check-jsonschema >/dev/null 2>&1 || { printf 'v2-review-metrics: check-jsonschema is required\n' >&2; exit 3; }
}

parse_emit_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --runtime-root=*) RUNTIME_ROOT="${1#--runtime-root=}"; shift ;;
      --runtime-root) RUNTIME_ROOT="${2:?--runtime-root requires dir}"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --phase-ref=*) PHASE_REF="${1#--phase-ref=}"; shift ;;
      --phase-ref) PHASE_REF="${2:?--phase-ref requires value}"; shift 2 ;;
      --review-ref=*) REVIEW_REF="${1#--review-ref=}"; shift ;;
      --review-ref) REVIEW_REF="${2:?--review-ref requires value}"; shift 2 ;;
      --review-host=*) REVIEW_HOST="${1#--review-host=}"; shift ;;
      --review-host) REVIEW_HOST="${2:?--review-host requires value}"; shift 2 ;;
      --review-kind=*) REVIEW_KIND="${1#--review-kind=}"; shift ;;
      --review-kind) REVIEW_KIND="${2:?--review-kind requires value}"; shift 2 ;;
      --finding-id=*) FINDING_ID="${1#--finding-id=}"; shift ;;
      --finding-id) FINDING_ID="${2:?--finding-id requires value}"; shift 2 ;;
      --severity=*) SEVERITY="${1#--severity=}"; shift ;;
      --severity) SEVERITY="${2:?--severity requires value}"; shift 2 ;;
      --disposition=*) DISPOSITION="${1#--disposition=}"; shift ;;
      --disposition) DISPOSITION="${2:?--disposition requires value}"; shift 2 ;;
      --summary=*) SUMMARY="${1#--summary=}"; shift ;;
      --summary) SUMMARY="${2:?--summary requires value}"; shift 2 ;;
      --prevented-defect-ref=*) PREVENTED_DEFECT_REF="${1#--prevented-defect-ref=}"; shift ;;
      --prevented-defect-ref) PREVENTED_DEFECT_REF="${2:?--prevented-defect-ref requires value}"; shift 2 ;;
      --follow-up-ref=*) FOLLOW_UP_REF="${1#--follow-up-ref=}"; shift ;;
      --follow-up-ref) FOLLOW_UP_REF="${2:?--follow-up-ref requires value}"; shift 2 ;;
      --superseded-by=*) SUPERSEDED_BY="${1#--superseded-by=}"; shift ;;
      --superseded-by) SUPERSEDED_BY="${2:?--superseded-by requires value}"; shift 2 ;;
      --occurred-at=*) OCCURRED_AT="${1#--occurred-at=}"; shift ;;
      --occurred-at) OCCURRED_AT="${2:?--occurred-at requires value}"; shift 2 ;;
      *) printf 'v2-review-metrics: unknown arg: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
  done
}

parse_report_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --runtime-root=*) RUNTIME_ROOT="${1#--runtime-root=}"; shift ;;
      --runtime-root) RUNTIME_ROOT="${2:?--runtime-root requires dir}"; shift 2 ;;
      --format=*) FORMAT="${1#--format=}"; shift ;;
      --format) FORMAT="${2:?--format requires value}"; shift 2 ;;
      --output=*) OUTPUT="${1#--output=}"; shift ;;
      --output) OUTPUT="${2:?--output requires path}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'v2-review-metrics: unknown arg: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
  done
}

severity_weight() {
  SEVERITY="$SEVERITY" yq -r '.severities[] | select(.severity == strenv(SEVERITY)) | .weight' "$REGISTRY"
}

validate_registry_value() {
  local kind="$1" value="$2"
  case "$kind" in
    severity)
      VALUE="$value" yq -e '.severities[] | select(.severity == strenv(VALUE))' "$REGISTRY" >/dev/null
      ;;
    disposition)
      VALUE="$value" yq -e '.dispositions[] | select(. == strenv(VALUE))' "$REGISTRY" >/dev/null
      ;;
  esac
}

cmd_emit() {
  parse_emit_args "$@"
  require_tools

  [ -n "$RUNTIME_ROOT" ] || { usage; exit 2; }
  [ -n "$PHASE_REF" ] || { usage; exit 2; }
  [ -n "$REVIEW_REF" ] || { usage; exit 2; }
  [ -n "$REVIEW_HOST" ] || { usage; exit 2; }
  [ -n "$REVIEW_KIND" ] || { usage; exit 2; }
  [ -n "$FINDING_ID" ] || { usage; exit 2; }
  [ -n "$SEVERITY" ] || { usage; exit 2; }
  [ -n "$DISPOSITION" ] || { usage; exit 2; }
  [ -n "$SUMMARY" ] || { usage; exit 2; }
  [ "$DISPOSITION" != "superseded" ] || [ -n "$SUPERSEDED_BY" ] || {
    printf 'v2-review-metrics: --superseded-by is required when disposition is superseded\n' >&2
    exit 2
  }

  validate_registry_value severity "$SEVERITY" || {
    printf 'v2-review-metrics: unknown severity: %s\n' "$SEVERITY" >&2
    exit 2
  }
  validate_registry_value disposition "$DISPOSITION" || {
    printf 'v2-review-metrics: unknown disposition: %s\n' "$DISPOSITION" >&2
    exit 2
  }

  case "$REVIEW_KIND" in plan|outcome|pr|pre-commit) ;; *) printf 'v2-review-metrics: unknown review kind: %s\n' "$REVIEW_KIND" >&2; exit 2 ;; esac

  local weight data event_json tmp
  weight=$(severity_weight)
  [ -n "$OCCURRED_AT" ] || OCCURRED_AT=$(now_utc)

  data=$(jq -n \
    --arg phase_ref "$PHASE_REF" \
    --arg review_ref "$REVIEW_REF" \
    --arg review_host "$REVIEW_HOST" \
    --arg review_kind "$REVIEW_KIND" \
    --arg finding_id "$FINDING_ID" \
    --arg severity "$SEVERITY" \
    --argjson severity_weight "$weight" \
    --arg disposition "$DISPOSITION" \
    --arg summary "$SUMMARY" \
    --arg prevented_defect_ref "$PREVENTED_DEFECT_REF" \
    --arg follow_up_ref "$FOLLOW_UP_REF" \
    --arg superseded_by "$SUPERSEDED_BY" \
    '{
      phase_ref: $phase_ref,
      review_ref: $review_ref,
      review_host: $review_host,
      review_kind: $review_kind,
      finding_id: $finding_id,
      severity: $severity,
      severity_weight: $severity_weight,
      disposition: $disposition,
      summary: $summary,
      privacy_classification: "private-runtime"
    }
    + (if $prevented_defect_ref == "" then {} else {prevented_defect_ref: $prevented_defect_ref} end)
    + (if $follow_up_ref == "" then {} else {follow_up_ref: $follow_up_ref} end)
    + (if $superseded_by == "" then {} else {superseded_by: $superseded_by} end)')

  event_json=$(jq -n \
    --arg occurred_at "$OCCURRED_AT" \
    --arg subject "$PHASE_REF" \
    --arg idempotency_key "review_finding_disposition:$REVIEW_REF:$FINDING_ID:$DISPOSITION" \
    --argjson data "$data" \
    '{
      schema_version: 1,
      event: "review_finding_disposition_recorded",
      occurred_at: $occurred_at,
      producer: {agent: "manager", mode: "review-metrics"},
      subject: $subject,
      idempotency_key: $idempotency_key,
      writable_action: true,
      data: $data
    }')

  tmp=$(mktemp -t v2-review-metrics.XXXXXX) || exit 2
  printf '%s\n' "$event_json" > "$tmp"
  if ! PYTHONWARNINGS=ignore check-jsonschema --schemafile "$SCHEMA" "$tmp" >/dev/null; then
    rm -f "$tmp"
    printf 'v2-review-metrics: event failed schema validation\n' >&2
    exit 2
  fi
  rm -f "$tmp"

  if [ "$QUIET" -eq 1 ]; then
    "$SCRIPT_DIR/v2-event-log.sh" append --runtime-root "$RUNTIME_ROOT" --quiet --event-json "$event_json"
  else
    "$SCRIPT_DIR/v2-event-log.sh" append --runtime-root "$RUNTIME_ROOT" --event-json "$event_json"
  fi
}

raw_events_json() {
  if [ ! -d "$RUNTIME_ROOT/events" ]; then
    printf '[]\n'
    return
  fi
  find "$RUNTIME_ROOT/events" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jsonl' 2>/dev/null \
    | sort \
    | while IFS= read -r f; do cat "$f"; done \
    | jq -R 'fromjson? | select(type == "object" and .event == "review_finding_disposition_recorded")' \
    | jq -s '.'
}

build_report_json() {
  local events
  events=$(raw_events_json)
  jq -n \
    --arg generated_at "$(now_utc)" \
    --argjson events "$events" '
    def disposition_counts($items): {
      accepted: ([$items[] | select(.data.disposition == "accepted")] | length),
      rejected: ([$items[] | select(.data.disposition == "rejected")] | length),
      disputed: ([$items[] | select(.data.disposition == "disputed")] | length),
      superseded: ([$items[] | select(.data.disposition == "superseded")] | length)
    };
    def accepted_score($items):
      [$items[] | select(.data.disposition == "accepted") | .data.severity_weight] | add // 0;
    def terminal_items:
      sort_by(.occurred_at, (.replay.byte_offset // 0))
      | group_by(.data.review_ref + "\u0000" + .data.finding_id)
      | map(last);
    ($events | terminal_items) as $terminal |
    {
      schema_version: {"name": "review-metrics-report", "version": "1.0.0", "min_reader": "1.0.0", "deprecated_at": null},
      generated_at: $generated_at,
      scoring_rule: "only accepted terminal findings contribute severity_weight",
      total_terminal_findings: ($terminal | length),
      accepted_weighted_score: accepted_score($terminal),
      disposition_counts: disposition_counts($terminal),
      phases: (
        $terminal
        | group_by(.data.phase_ref)
        | map(. as $phase_items | {
            phase_ref: $phase_items[0].data.phase_ref,
            terminal_findings: ($phase_items | length),
            accepted_weighted_score: accepted_score($phase_items),
            disposition_counts: disposition_counts($phase_items),
            by_host: (
              $phase_items
              | group_by(.data.review_host)
              | map(. as $host_items | {
                  review_host: $host_items[0].data.review_host,
                  terminal_findings: ($host_items | length),
                  accepted_weighted_score: accepted_score($host_items),
                  disposition_counts: disposition_counts($host_items)
                })
            )
          })
      ),
      findings: ($terminal | map({
        phase_ref: .data.phase_ref,
        review_ref: .data.review_ref,
        review_host: .data.review_host,
        review_kind: .data.review_kind,
        finding_id: .data.finding_id,
        severity: .data.severity,
        severity_weight: .data.severity_weight,
        disposition: .data.disposition,
        summary: .data.summary,
        prevented_defect_ref: (.data.prevented_defect_ref // null),
        follow_up_ref: (.data.follow_up_ref // null),
        superseded_by: (.data.superseded_by // null),
        occurred_at: .occurred_at
      }))
    }'
}

render_markdown() {
  jq -r '
    "# Studio v2 Review Metrics Report",
    "",
    "- Scoring: \(.scoring_rule)",
    "- Terminal findings: \(.total_terminal_findings)",
    "- Accepted weighted score: \(.accepted_weighted_score)",
    "",
    "## Dispositions",
    "",
    "- Accepted: \(.disposition_counts.accepted)",
    "- Rejected: \(.disposition_counts.rejected)",
    "- Disputed: \(.disposition_counts.disputed)",
    "- Superseded: \(.disposition_counts.superseded)",
    "",
    "## Phases",
    "",
    (if (.phases | length) == 0 then "_None_"
     else (.phases[] | "### `\(.phase_ref)`\n\n- Terminal findings: \(.terminal_findings)\n- Accepted weighted score: \(.accepted_weighted_score)\n- Accepted/rejected/disputed/superseded: \(.disposition_counts.accepted)/\(.disposition_counts.rejected)/\(.disposition_counts.disputed)/\(.disposition_counts.superseded)\n- By host:\n\(.by_host | map("  - `" + .review_host + "`: score " + (.accepted_weighted_score | tostring) + ", findings " + (.terminal_findings | tostring)) | join("\n"))")
     end),
    "",
    "## Findings",
    "",
    (if (.findings | length) == 0 then "_None_"
     else (.findings[] | "- `\(.phase_ref)` / `\(.review_host)` / `\(.finding_id)`: \(.severity) \(.disposition), weight \(.severity_weight), \(.summary)")
     end)
  '
}

write_or_print() {
  if [ -n "$OUTPUT" ]; then
    cat > "$OUTPUT"
  else
    cat
  fi
}

cmd_report() {
  parse_report_args "$@"
  require_tools
  [ -n "$RUNTIME_ROOT" ] || { usage; exit 2; }
  case "$FORMAT" in json|markdown) ;; *) usage; exit 2 ;; esac

  local report_json
  report_json=$(build_report_json)
  if [ "$FORMAT" = "json" ]; then
    printf '%s\n' "$report_json" | write_or_print
  else
    printf '%s\n' "$report_json" | render_markdown | write_or_print
  fi
}

case "$COMMAND" in
  emit) cmd_emit "$@" ;;
  report) cmd_report "$@" ;;
  -h|--help|"") usage; [ -n "$COMMAND" ] && exit 0 || exit 2 ;;
  *) printf 'v2-review-metrics: unknown command: %s\n' "$COMMAND" >&2; usage; exit 2 ;;
esac
