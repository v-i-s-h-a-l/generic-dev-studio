#!/usr/bin/env bash
# studio-project-pulse.sh — manual Project board pulse: summarise items added,
# closed, status-changed, or needing review since the last snapshot.
#
# Cadence: manual-only. Wire to /loop or a LaunchAgent later if usage warrants;
# cron/per-session emission is intentionally out of scope (#896) until the
# data plumbing has been exercised by hand. Issue #818 §Views and reporting
# parents this.
#
# Destination: local private — the studio per-project analysis directory
# (resolved via lib-paths.sh). No issue comments, no Slack — the board
# itself is authoritative; the pulse is a diff over time, not a
# notification channel.
#
# Mechanism: each run snapshots the current Project items (via
# scripts/studio-project-state.sh --json) into the project's state directory
# (resolved through resolve_project_root_for) under
# `.runtime/state/project-board/<utc>.json` and diffs against the previous
# snapshot's `latest.json` pointer. Reader and writer primitives are not
# changed (#896 non-goal).
#
# Usage:
#   scripts/studio-project-pulse.sh
#   scripts/studio-project-pulse.sh --format json
#   scripts/studio-project-pulse.sh --format md --out pulse.md
#   scripts/studio-project-pulse.sh --format md --out <project-analysis-dir>/pulse.md
#   scripts/studio-project-pulse.sh --since /path/to/old-snapshot.json
#   scripts/studio-project-pulse.sh --since none          # baseline only
#   scripts/studio-project-pulse.sh --no-snapshot         # do not advance the snapshot
#   scripts/studio-project-pulse.sh --quiet               # exit 0 silently when no diff
#   scripts/studio-project-pulse.sh --project-board user:v-i-s-h-a-l:1

set -u
set -o pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-artifact-cleanup.sh
. "$SCRIPT_DIR/lib-artifact-cleanup.sh"

FORMAT="human"
OUT=""
SINCE="latest"
WRITE_SNAPSHOT=1
QUIET=0
LIMIT=""
PROJECT_BOARD=""

usage() { sed -n '2,30p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --format) FORMAT="${2:?usage: --format human|json|md}"; shift 2 ;;
    --out) OUT="${2:?usage: --out <path>}"; shift 2 ;;
    --since) SINCE="${2:?usage: --since latest|none|<path>}"; shift 2 ;;
    --no-snapshot) WRITE_SNAPSHOT=0; shift ;;
    --quiet) QUIET=1; shift ;;
    --limit) LIMIT="${2:?usage: --limit <n>}"; shift 2 ;;
    --project-board) PROJECT_BOARD="${2:?usage: --project-board <token>}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'studio-project-pulse: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$FORMAT" in
  human|json|md) ;;
  *) printf 'studio-project-pulse: --format must be human|json|md (got %s)\n' "$FORMAT" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { printf 'studio-project-pulse: jq required\n' >&2; exit 127; }

PROJECT=$(resolve_project) || exit 1
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
PROJECT_ROOT_REAL=$(cd "$PROJECT_ROOT" && pwd -P) || exit 1
ANALYSIS_DIR="$PROJECT_ROOT/analysis"
SNAPSHOT_DIR="$PROJECT_ROOT/.runtime/state/project-board"
mkdir -p "$SNAPSHOT_DIR"

NOW_UTC=$(date -u +"%Y%m%dT%H%M%SZ")
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CURRENT_SNAPSHOT="$SNAPSHOT_DIR/$NOW_UTC.json"
LATEST_LINK="$SNAPSHOT_DIR/latest.json"

tmpdir=$(mktemp -d -t studio-project-pulse.XXXXXX); register_artifact tmpdir "$tmpdir"

# Fetch current state via the reader primitive (untouched per #896 non-goal).
reader=( "$SCRIPT_DIR/studio-project-state.sh" --json )
[ -n "$LIMIT" ] && reader+=( --limit "$LIMIT" )
[ -n "$PROJECT_BOARD" ] && reader+=( --project-board "$PROJECT_BOARD" )

if ! "${reader[@]}" > "$tmpdir/current.json" 2> "$tmpdir/current.err"; then
  err_msg=$(cat "$tmpdir/current.err" || true)
  printf 'studio-project-pulse: project state read failed: %s\n' "$err_msg" >&2
  exit 1
fi

# Resolve the previous snapshot.
prev_path=""
case "$SINCE" in
  none) prev_path="" ;;
  latest)
    if [ -e "$LATEST_LINK" ]; then
      prev_path=$(readlink "$LATEST_LINK" 2>/dev/null || true)
      case "$prev_path" in
        /*) ;;
        "") prev_path="$LATEST_LINK" ;;
        *) prev_path="$SNAPSHOT_DIR/$prev_path" ;;
      esac
      [ -r "$prev_path" ] || prev_path=""
    fi
    ;;
  *) prev_path="$SINCE" ;;
esac

if [ -n "$prev_path" ] && [ ! -r "$prev_path" ]; then
  printf 'studio-project-pulse: --since path not readable: %s\n' "$prev_path" >&2
  exit 2
fi

if [ -n "$prev_path" ]; then
  cp "$prev_path" "$tmpdir/previous.json"
elif [ "$SINCE" = "none" ]; then
  cp "$tmpdir/current.json" "$tmpdir/previous.json"
else
  printf '[]\n' > "$tmpdir/previous.json"
fi

# Compute the diff. Items are keyed by issue_number || url || title to survive
# missing issue numbers (draft items, cross-repo items the reader could not
# resolve to an issue node).
diff_json=$(
  jq -n \
    --slurpfile prev "$tmpdir/previous.json" \
    --slurpfile curr "$tmpdir/current.json" \
    --arg ts "$NOW_ISO" \
    --arg prev_path "$prev_path" '
      def normalise:
        map({
          key: ((.issue_number // .url // .title) | tostring),
          issue_number: (.issue_number // null),
          url: (.url // ""),
          title: (.title // ""),
          status: (.status // ""),
          track: (.track // ""),
          phase: (.phase // ""),
          size: (.size // ""),
          sibling_host_reviewed: (.sibling_host_reviewed // (."sibling host reviewed" // "")),
          labels: (.labels // [])
        });
      def index_by_key:
        normalise | map({(.key): .}) | add // {};
      ($prev[0] // []) as $p
      | ($curr[0] // []) as $c
      | ($p | index_by_key) as $pm
      | ($c | index_by_key) as $cm
      | ($pm | keys_unsorted) as $pk
      | ($cm | keys_unsorted) as $ck
      | ($cm | to_entries | map(select(($pm[.key] // null) == null)) | map(.value)) as $added
      | ($pm | to_entries | map(select(($cm[.key] // null) == null)) | map(.value)) as $removed
      | (
          $cm | to_entries
          | map(
              .key as $k
              | .value as $cv
              | ($pm[$k] // null) as $pv
              | select($pv != null and $pv.status != $cv.status)
              | {key: $k, before: $pv.status, after: $cv.status, item: $cv}
            )
        ) as $status_changes
      | ($status_changes | map(select(.after == "Done")) | map(.item)) as $closed_in_place
      | ($removed | map(select(.status != "Done"))) as $removed_open
      | ($closed_in_place + ($removed | map(select(.status == "Done")))) as $closed
      | ($status_changes | map(select(.after == "In Progress")) | map(.item)) as $started
      | (
          $cm | to_entries
          | map(.value)
          | map(select(.sibling_host_reviewed == "Needs review"))
        ) as $needs_review_now
      | (
          $status_changes
          | map(select(.after != "Done" and .after != "In Progress"))
          | map({key, before, after, item})
        ) as $other_status_changes
      | (
          $cm | to_entries
          | map(
              .key as $k
              | .value as $cv
              | ($pm[$k] // null) as $pv
              | select($pv != null)
              | select($pv.sibling_host_reviewed == "Needs review" and $cv.sibling_host_reviewed != "Needs review")
              | {key: $k, before: $pv.sibling_host_reviewed, after: $cv.sibling_host_reviewed, item: $cv}
            )
        ) as $review_landed
      | {
          generated_at: $ts,
          previous_snapshot: ($prev_path | select(length > 0) // null),
          totals: {
            previous: ($p | length),
            current: ($c | length),
            added: ($added | length),
            closed: ($closed | length),
            removed_open: ($removed_open | length),
            started: ($started | length),
            needs_review_now: ($needs_review_now | length),
            review_landed: ($review_landed | length),
            other_status_changes: ($other_status_changes | length)
          },
          by_status: ($c | normalise | group_by(.status) | map({status: (.[0].status // "No Status"), count: length})),
          added: $added,
          closed: $closed,
          removed_open: $removed_open,
          started: $started,
          needs_review_now: $needs_review_now,
          review_landed: $review_landed,
          other_status_changes: $other_status_changes
        }
    '
)

# Did anything change in a way worth surfacing?
change_total=$(printf '%s\n' "$diff_json" | jq '
  [.totals.added,
   .totals.closed,
   .totals.removed_open,
   .totals.started,
   .totals.review_landed,
   .totals.other_status_changes] | add
')
needs_review_total=$(printf '%s\n' "$diff_json" | jq '.totals.needs_review_now')

# Persist the snapshot before any output, so subsequent runs have a baseline
# even when --quiet exits before printing.
if [ "$WRITE_SNAPSHOT" -eq 1 ]; then
  cp "$tmpdir/current.json" "$CURRENT_SNAPSHOT"
  ln -sfn "$(basename "$CURRENT_SNAPSHOT")" "$LATEST_LINK"
fi

if [ "$QUIET" -eq 1 ] && [ "$change_total" -eq 0 ] && [ "$needs_review_total" -eq 0 ]; then
  exit 0
fi

render_human() {
  printf '%s\n' "$diff_json" | jq -r --arg ts "$NOW_ISO" --arg prev "$prev_path" '
    def line(item):
      "  #\((item.issue_number // "-")) [\(item.status // "No Status")] \(item.title // "")"
      + " -- track=\((item.track // "") | if . == "" then "-" else . end)"
      + " phase=\((item.phase // "") | if . == "" then "-" else . end)"
      + " review=\((item.sibling_host_reviewed // "") | if . == "" then "-" else . end)"
      + (if (item.url // "") == "" then "" else " \(item.url)" end);
    def section(title; arr):
      "## \(title) (\(arr | length))",
      (if (arr | length) == 0 then "  (none)" else (arr[] | line(.)) end),
      "";
    "Project pulse @ \($ts)",
    "Previous snapshot: \(if $prev == "" then "(none — baseline)" else $prev end)",
    "",
    "Totals: items=\(.totals.current) added=\(.totals.added) closed=\(.totals.closed)"
    + " started=\(.totals.started) needs_review=\(.totals.needs_review_now)"
    + " review_landed=\(.totals.review_landed) status_other=\(.totals.other_status_changes)"
    + " removed_open=\(.totals.removed_open)",
    "",
    section("Added"; .added),
    section("Started"; .started),
    section("Closed"; .closed),
    section("Removed while still open"; .removed_open),
    section("Needs sibling-host review"; .needs_review_now),
    section("Sibling-host review landed"; .review_landed | map(.item)),
    section("Other status changes"; .other_status_changes | map(.item))
  '
}

render_md() {
  printf '%s\n' "$diff_json" | jq -r --arg ts "$NOW_ISO" --arg prev "$prev_path" '
    def line(item):
      "- #\((item.issue_number // "-")) — \(item.title // "") "
      + "(status=\((item.status // "") | if . == "" then "-" else . end), "
      + "track=\((item.track // "") | if . == "" then "-" else . end), "
      + "phase=\((item.phase // "") | if . == "" then "-" else . end), "
      + "review=\((item.sibling_host_reviewed // "") | if . == "" then "-" else . end))"
      + (if (item.url // "") == "" then "" else " — \(item.url)" end);
    def section(title; arr):
      "## \(title) (\(arr | length))",
      "",
      (if (arr | length) == 0 then "_(none)_" else (arr[] | line(.)) end),
      "";
    "# Project board pulse — \($ts)",
    "",
    "Previous snapshot: \(if $prev == "" then "_baseline (no previous snapshot)_" else "`\($prev)`" end)",
    "",
    "## Totals",
    "",
    "| Metric | Value |",
    "|---|---|",
    "| Items on board | \(.totals.current) |",
    "| Added since last pulse | \(.totals.added) |",
    "| Closed since last pulse | \(.totals.closed) |",
    "| Started (→ In Progress) | \(.totals.started) |",
    "| Needs sibling-host review | \(.totals.needs_review_now) |",
    "| Sibling-host review landed | \(.totals.review_landed) |",
    "| Other status changes | \(.totals.other_status_changes) |",
    "| Removed while still open | \(.totals.removed_open) |",
    "",
    section("Added"; .added),
    section("Started"; .started),
    section("Closed"; .closed),
    section("Removed while still open"; .removed_open),
    section("Needs sibling-host review"; .needs_review_now),
    section("Sibling-host review landed"; .review_landed | map(.item)),
    section("Other status changes"; .other_status_changes | map(.item))
  '
}

emit() {
  case "$FORMAT" in
    json) printf '%s\n' "$diff_json" ;;
    md) render_md ;;
    human) render_human ;;
  esac
}

if [ -n "$OUT" ]; then
  if [ "$OUT" = "-" ]; then
    emit
  else
    case "$OUT" in
      /*) out_path="$OUT" ;;
      *) out_path="$ANALYSIS_DIR/$OUT" ;;
    esac
    case "$out_path" in
      "$PROJECT_ROOT"/*|"$PROJECT_ROOT_REAL"/*) ;;
      *)
        printf 'studio-project-pulse: --out must stay under project runtime root: %s\n' "$PROJECT_ROOT" >&2
        printf 'studio-project-pulse: use a relative path for %s/analysis/ or an absolute path below that root\n' "$PROJECT_ROOT" >&2
        exit 2
        ;;
    esac
    case "$out_path" in
      ../*|*/../*|*/..)
        printf 'studio-project-pulse: --out must not contain parent-directory traversal: %s\n' "$OUT" >&2
        exit 2
        ;;
    esac
    out_dir=$(dirname "$out_path")
    existing_parent="$out_dir"
    missing_suffix=""
    while [ ! -e "$existing_parent" ]; do
      missing_suffix="/$(basename "$existing_parent")$missing_suffix"
      next_parent=$(dirname "$existing_parent")
      [ "$next_parent" != "$existing_parent" ] || break
      existing_parent="$next_parent"
    done
    existing_parent_real=$(cd "$existing_parent" && pwd -P) || exit 1
    planned_dir_real="$existing_parent_real$missing_suffix"
    case "$planned_dir_real" in
      "$PROJECT_ROOT_REAL"|"$PROJECT_ROOT_REAL"/*) ;;
      *)
        printf 'studio-project-pulse: --out parent directory escapes project runtime root: %s\n' "$OUT" >&2
        exit 2
        ;;
    esac
    mkdir -p "$out_dir"
    out_dir_real=$(cd "$out_dir" && pwd -P) || exit 1
    out_real="$out_dir_real/$(basename "$out_path")"
    case "$out_real" in
      "$PROJECT_ROOT_REAL"/*) ;;
      *)
        printf 'studio-project-pulse: --out must stay under project runtime root: %s\n' "$PROJECT_ROOT" >&2
        printf 'studio-project-pulse: use a relative path for %s/analysis/ or an absolute path below that root\n' "$PROJECT_ROOT" >&2
        exit 2
        ;;
    esac
    if [ -L "$out_path" ] || [ -L "$out_real" ]; then
      printf 'studio-project-pulse: --out must not target a symlink: %s\n' "$OUT" >&2
      exit 2
    fi
    emit > "$out_real"
    printf 'studio-project-pulse: wrote %s pulse to %s\n' "$FORMAT" "$out_real" >&2
  fi
else
  emit
fi
