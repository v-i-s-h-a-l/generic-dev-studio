#!/usr/bin/env bash
# chanakya-snap.sh — regenerate Chanakya snapshot files.
#
# Usage:
#   scripts/chanakya-snap.sh <domain>        # regenerate one
#   scripts/chanakya-snap.sh all             # regenerate all four
#
# Domains:
#   briefs           Task summary from master plan + chanakya-inbox.
#   debt             Build + unit/UI test debt from master plan.
#   feedback-inbox   Unprocessed studio-feedback items per source scope.
#   events-tail      Last 100 events from today's event log.
#
# Output location (committed defaults are fallbacks only — never overwritten):
#   Runtime: ~/.dev-studio/<project>/.runtime/state/chanakya-snapshots/<domain>.json
#   Skeleton (committed fallback, read-only to this script): chanakya/snapshots/<domain>.json
#
# Writes are atomic (temp file → mv). On error, leaves previous snapshot in
# place and emits snapshot_failed event. Each snapshot has generated_at
# (ISO-8601 UTC) and schema: 1.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

domain="${1:-}"
if [ -z "$domain" ]; then
  printf 'usage: chanakya-snap.sh <briefs|debt|feedback-inbox|events-tail|all>\n' >&2
  exit 2
fi

# Resolve project — fail-closed per contract: no project, no write.
PROJECT=$(resolve_project 2>/dev/null) || {
  printf 'chanakya-snap: cannot resolve project; aborting\n' >&2
  exit 1
}
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
SNAP_DIR="$PROJECT_ROOT/.runtime/state/chanakya-snapshots"
mkdir -p "$SNAP_DIR" 2>/dev/null || true

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ms()  { python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null \
              || date +%s000; }

# Emit a snapshot_* event (best-effort, never blocks).
emit_snap_event() {
  local event="$1" data="$2"
  append_event chanakya "$event" "" "$data" 2>/dev/null || true
}

# Atomically write $2 (JSON string) to $1. Returns 1 if jq rejects the payload.
atomic_write_json() {
  local target="$1" payload="$2" tmp
  tmp=$(mktemp "$SNAP_DIR/.tmp.XXXXXX") || return 1
  printf '%s' "$payload" > "$tmp" || { rm -f "$tmp"; return 1; }
  # Validate before committing.
  if ! jq empty "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$target" || { rm -f "$tmp"; return 1; }
  return 0
}

# -----------------------------------------------------------------------------
# Producer: briefs
# -----------------------------------------------------------------------------
# Read `plans/tasks/*.yaml` (canonical post-#245 A.3). Build the same JSON
# shape consumers were getting from the legacy master-plan parse. State is
# translated from the canonical vocabulary back to the legacy display vocab
# (e.g. proposed→pending, archived→done) so consumers see no shape change.
# Active list = state ∉ {merged, verified, archived, cancelled, superseded};
# sorted by updated_at desc; capped at 30. by_status counts ALL tasks.
produce_briefs() {
  local tasks_dir="$PROJECT_ROOT/plans/tasks"
  local count_yaml
  count_yaml=$(find "$tasks_dir" -maxdepth 1 -type f -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${count_yaml:-0}" -eq 0 ]; then
    # Empty-but-valid snapshot — consumers will full-load fallback.
    atomic_write_json "$SNAP_DIR/briefs.json" \
      "$(printf '{"generated_at":"%s","schema":1,"project":"%s","tasks":[],"total":0,"note":"no plans/tasks/ yaml"}' \
         "$(now_iso)" "$PROJECT")"
    return $?
  fi

  local briefs_dir="$PROJECT_ROOT/plans/briefs"
  local entries
  entries=$(
    for task_yaml in "$tasks_dir"/*.yaml; do
      [ -f "$task_yaml" ] || continue
      local brief_id summary_json task_json
      brief_id=$(yq -r '.links.brief // ""' "$task_yaml" 2>/dev/null || echo "")
      summary_json='null'
      if [ -n "$brief_id" ] && [ -f "$briefs_dir/${brief_id}.yaml" ]; then
        summary_json=$(yq -o=json '.summary // null' "$briefs_dir/${brief_id}.yaml" 2>/dev/null || echo 'null')
        printf '%s' "$summary_json" | jq empty >/dev/null 2>&1 || summary_json='null'
      fi
      task_json=$(yq -o=json '{
        "id": (.legacy_task_id // .id),
        "title": (.title // ""),
        "raw_state": (.state // "unknown"),
        "priority": (.legacy_priority // ""),
        "complexity": (.legacy_complexity // ((.size // "") | upcase)),
        "updated_at": (.updated_at // "")
      }' "$task_yaml" 2>/dev/null || echo '{}')
      printf '%s' "$task_json" | jq --argjson summary "$summary_json" '. + {summary: $summary}'
    done | jq -s '.'
  )

  if [ -z "$entries" ] || ! printf '%s' "$entries" | jq empty 2>/dev/null; then
    emit_snap_event snapshot_failed '{"domain":"briefs","error":"yq_failed"}'
    return 1
  fi

  # canonical → legacy display status mirrors lib-ledger.sh::_state_to_legacy_status.
  local out
  out=$(printf '%s' "$entries" | jq -c '
    def to_legacy(s):
      ({
        "proposed":"pending", "briefed":"briefed", "in-progress":"in-progress",
        "done":"done", "verified":"verified", "merged":"merged",
        "blocked":"blocked", "cancelled":"cancelled", "archived":"done",
        "reopened":"pending", "deferred":"deferred"
      }[s]) // s;
    def title50(s): if (s|length) > 50 then ((s[0:49]) + "…") else s end;
    map(.status = to_legacy(.raw_state))
    | (reduce .[] as $t ({}; .[$t.status] = ((.[$t.status] // 0) + 1))) as $by_status
    | length as $total_all
    | map(select(.raw_state as $rs | ["merged","verified","archived","cancelled","superseded"] | index($rs) | not))
    | sort_by(.updated_at) | reverse
    | .[0:30]
    | map({id, title: title50(.title), status, priority, complexity, summary})
    | {tasks: ., shown: length, by_status: $by_status, total: $total_all}
  ')

  if [ -z "$out" ] || ! printf '%s' "$out" | jq empty 2>/dev/null; then
    emit_snap_event snapshot_failed '{"domain":"briefs","error":"jq_projection_failed"}'
    return 1
  fi

  local payload
  payload=$(printf '%s' "$out" | jq -c \
    --arg generated_at "$(now_iso)" \
    --arg project "$PROJECT" \
    '{generated_at: $generated_at, schema: 1, project: $project, total, shown, by_status, tasks}')

  atomic_write_json "$SNAP_DIR/briefs.json" "$payload"
}

# -----------------------------------------------------------------------------
# Producer: debt
# -----------------------------------------------------------------------------
produce_debt() {
  local plans="$PROJECT_ROOT/plans"
  local debt_yaml="$plans/build-debt.yaml"
  local preamble="$plans/master-plan-preamble.md"

  # Build counter — canonical source post-#273 is plans/build-debt.yaml.
  local build_j='null'
  if [ -f "$debt_yaml" ]; then
    build_j=$(yq -o=json '{
      "counter": (.counter // 0),
      "warn": (.warn_at // 0),
      "block": (.block_at // 0),
      "state": (.state // "unknown"),
      "last_green": (.last_green // "")
    }' "$debt_yaml" 2>/dev/null)
    [ -z "$build_j" ] && build_j='null'
    if ! printf '%s' "$build_j" | jq empty 2>/dev/null; then
      build_j='null'
    fi
  fi

  # Unit/UI test debt blocks live in master-plan-preamble.md (editorial,
  # owned by the user). Same awk pattern that used to walk chanakya-master.md
  # — the blocks moved to the preamble in #273 / Shape B.
  local unit_j='null' ui_j='null'
  if [ -f "$preamble" ]; then
    local parsed
    parsed=$(awk '
      function emit(section) {
        printf "%s|%s|%s|%s|%s|%s\n", section, counter, warn, block, state, last_green
        counter=""; warn=""; block=""; state=""; last_green=""
      }
      /^### Unit Test Debt/  { if (sec!="") emit(sec); sec="unit_test"; next }
      /^### UI Test Debt/    { if (sec!="") emit(sec); sec="ui_test";   next }
      /^## Module Index/     { if (sec!="") emit(sec); sec=""; next }
      /^## Test Debt/        { next }
      sec!="" && /^- Counter:/ {
        line=$0
        t=line; sub(/^.*Counter: */, "", t); sub(/ .*$/, "", t); counter=t+0
        t=line; sub(/^.*warn@/, "", t);      sub(/[^0-9].*$/, "", t); warn=t+0
        t=line; sub(/^.*block@/, "", t);     sub(/[^0-9].*$/, "", t); block=t+0
        next
      }
      sec!="" && /^- State:/ {
        line=$0; sub(/^- State: */, "", line); sub(/ *<!--.*/, "", line); sub(/ *$/, "", line)
        state=line; next
      }
      sec!="" && /^- Last green/ {
        line=$0; sub(/^- Last green[^:]*: */, "", line); sub(/ *<!--.*/, "", line); sub(/ *$/, "", line)
        last_green=line; next
      }
      END { if (sec!="") emit(sec) }
    ' "$preamble")

    json_for_section() {
      local sec="$1"
      local line
      line=$(printf '%s\n' "$parsed" | awk -F'|' -v s="$sec" '$1==s {print; exit}')
      if [ -z "$line" ]; then printf 'null'; return; fi
      local counter warn block state last_green
      counter=$(printf '%s' "$line" | awk -F'|' '{print $2}')
      warn=$(printf    '%s' "$line" | awk -F'|' '{print $3}')
      block=$(printf   '%s' "$line" | awk -F'|' '{print $4}')
      state=$(printf   '%s' "$line" | awk -F'|' '{print $5}')
      last_green=$(printf '%s' "$line" | awk -F'|' '{print $6}')
      jq -nc \
        --argjson counter "${counter:-0}" \
        --argjson warn "${warn:-0}" \
        --argjson block "${block:-0}" \
        --arg state "${state:-unknown}" \
        --arg last_green "${last_green:-}" \
        '{counter: $counter, warn: $warn, block: $block, state: $state, last_green: $last_green}'
    }

    unit_j=$(json_for_section unit_test)
    ui_j=$(json_for_section ui_test)
  fi

  if [ "$build_j" = "null" ] && [ "$unit_j" = "null" ] && [ "$ui_j" = "null" ]; then
    atomic_write_json "$SNAP_DIR/debt.json" \
      "$(printf '{"generated_at":"%s","schema":1,"project":"%s","note":"no build-debt yaml or preamble","build":null,"unit_test":null,"ui_test":null}' \
         "$(now_iso)" "$PROJECT")"
    return $?
  fi

  local payload
  payload=$(jq -nc \
    --arg generated_at "$(now_iso)" \
    --arg project "$PROJECT" \
    --argjson build "$build_j" \
    --argjson unit "$unit_j" \
    --argjson ui "$ui_j" \
    '{generated_at: $generated_at, schema: 1, project: $project, build: $build, unit_test: $unit, ui_test: $ui}')

  atomic_write_json "$SNAP_DIR/debt.json" "$payload"
}

# -----------------------------------------------------------------------------
# Producer: feedback-inbox
# -----------------------------------------------------------------------------
# Studio-feedback routes into the generic-dev-studio feedback-inbox scoped by
# source project (see _shared/primitives/file-locations.md). For a non-gds consumer, we
# show feedback that originated in THIS project; for gds itself, we show
# all scopes combined.
produce_feedback_inbox() {
  # Base layout: ~/.dev-studio/generic-dev-studio/feedback-inbox/<scope>/*.md
  # where <scope> = source project slug. When run in gds we snapshot all
  # scopes (the studio's own combined inbox); when run anywhere else we
  # snapshot only the slice routed to this project.
  local base find_depth
  if [ "$PROJECT" = "generic-dev-studio" ]; then
    base="$(resolve_project_root_for generic-dev-studio)/feedback-inbox"
    find_depth=2
  else
    base=$(resolve_feedback_inbox_for "$PROJECT")
    find_depth=1
  fi
  if [ ! -d "$base" ]; then
    atomic_write_json "$SNAP_DIR/feedback-inbox.json" \
      "$(printf '{"generated_at":"%s","schema":1,"project":"%s","total_pending":0,"by_scope":{},"pending":[]}' \
         "$(now_iso)" "$PROJECT")"
    return $?
  fi

  # Enumerate unprocessed files. Extract scope (parent dir), kind (from
  # frontmatter), and mtime. Cap at 50 items for snapshot size.
  local tmp_tsv
  tmp_tsv=$(mktemp)
  find "$base" -mindepth "$find_depth" -maxdepth "$find_depth" -type f -name '*.md' \
    -not -path '*/processed/*' 2>/dev/null > "$tmp_tsv.paths"

  local raw_tsv_file="$tmp_tsv"
  : > "$raw_tsv_file"
  local f scope name mtime_v kind
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$find_depth" -eq 1 ]; then
      scope="$PROJECT"
    else
      scope=$(basename "$(dirname "$f")")
    fi
    name=$(basename "$f")
    mtime_v=$(mtime "$f" 2>/dev/null) || mtime_v=0
    kind=$(awk 'BEGIN{c=0} /^---/{c++; if(c==2)exit; next} c==1 && /^kind:/{sub(/^kind:[[:space:]]*/,""); print; exit}' "$f" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\n' "$scope" "$name" "$kind" "$mtime_v" "$f" >> "$raw_tsv_file"
  done < "$tmp_tsv.paths"
  rm -f "$tmp_tsv.paths"

  # Sort by mtime desc; awk then serializes to JSON array.
  local TAB
  TAB=$(printf '\t')
  local items_json
  items_json=$(sort -t"$TAB" -k4,4nr "$raw_tsv_file" | head -n 50 | awk -F'\t' '
        function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
        BEGIN { printf "["; n=0 }
        NF>=5 {
          printf "%s{\"scope\":\"%s\",\"file\":\"%s\",\"kind\":\"%s\",\"mtime\":%s,\"path\":\"%s\"}",
                 (n>0?",":""), esc($1), esc($2), esc($3), ($4==""?0:$4), esc($5)
          n++
        }
        END { printf "]" }
      ')
  rm -f "$raw_tsv_file"

  if [ -z "$items_json" ] || ! printf '%s' "$items_json" | jq empty 2>/dev/null; then
    items_json='[]'
  fi

  local total by_scope jq_prog_groupby
  total=$(printf '%s' "$items_json" | jq length)
  jq_prog_groupby='[.[].scope] | group_by(.) | map({key: .[0], value: length}) | from_entries'
  by_scope=$(printf '%s' "$items_json" | jq -c "$jq_prog_groupby")

  local payload
  payload=$(jq -nc \
    --arg generated_at "$(now_iso)" \
    --arg project "$PROJECT" \
    --argjson total "$total" \
    --argjson by_scope "$by_scope" \
    --argjson pending "$items_json" \
    '{generated_at: $generated_at, schema: 1, project: $project, total_pending: $total, by_scope: $by_scope, pending: $pending}')

  atomic_write_json "$SNAP_DIR/feedback-inbox.json" "$payload"
}

# -----------------------------------------------------------------------------
# Producer: events-tail
# -----------------------------------------------------------------------------
# Last 100 events from today's log. Each line is already a JSON object; we
# parse + re-emit to guarantee well-formed output.
produce_events_tail() {
  local log
  log=$(resolve_event_log 2>/dev/null) || log=""

  local events_json='[]' tail_prog
  # Cap at 30 — enough for recent-activity summary in status mode, fits
  # under the 5KB per-snapshot budget even for noisy days. Full log is one
  # file away for consumers that need more.
  tail_prog='.[-25:]'
  if [ -n "$log" ] && [ -f "$log" ]; then
    # jq -s parses the file as a stream of JSON values (each line) into an
    # array; take the last 100.
    events_json=$(jq -s "$tail_prog" "$log" 2>/dev/null || echo '[]')
    if ! printf '%s' "$events_json" | jq empty 2>/dev/null; then
      events_json='[]'
    fi
  fi

  local count
  count=$(printf '%s' "$events_json" | jq length)

  # Drop log_file from payload — it's derivable via resolve_event_log() and
  # eats ~120 bytes of fixed overhead. Consumers that want the path can
  # resolve it themselves.
  local payload
  payload=$(jq -nc \
    --arg generated_at "$(now_iso)" \
    --arg project "$PROJECT" \
    --argjson count "$count" \
    --argjson events "$events_json" \
    '{generated_at: $generated_at, schema: 1, project: $project, count: $count, events: $events}')

  atomic_write_json "$SNAP_DIR/events-tail.json" "$payload"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
run_one() {
  local d="$1"
  local start end dur size target
  start=$(now_ms)
  target="$SNAP_DIR/${d}.json"
  local ok=1
  case "$d" in
    briefs)         produce_briefs         || ok=0 ;;
    debt)           produce_debt           || ok=0 ;;
    feedback-inbox) produce_feedback_inbox || ok=0 ;;
    events-tail)    produce_events_tail    || ok=0 ;;
    *)
      printf 'chanakya-snap: unknown domain %s\n' "$d" >&2
      return 2
      ;;
  esac
  end=$(now_ms)
  dur=$(( end - start ))
  if [ "$ok" -eq 1 ] && [ -f "$target" ]; then
    size=$(wc -c < "$target" | tr -d ' ')
    emit_snap_event snapshot_generated \
      "{\"domain\":\"$d\",\"duration_ms\":$dur,\"size_bytes\":$size,\"caller\":\"${SNAP_CALLER:-cli}\"}"
    printf 'wrote %s (%s bytes, %sms)\n' "$target" "$size" "$dur"
    return 0
  else
    emit_snap_event snapshot_failed \
      "{\"domain\":\"$d\",\"error\":\"producer_failed\",\"duration_ms\":$dur}"
    printf 'chanakya-snap: %s producer failed\n' "$d" >&2
    return 1
  fi
}

case "$domain" in
  all)
    rc=0
    for d in briefs debt feedback-inbox events-tail; do
      run_one "$d" || rc=1
    done
    exit "$rc"
    ;;
  briefs|debt|feedback-inbox|events-tail)
    run_one "$domain"
    exit $?
    ;;
  *)
    printf 'chanakya-snap: unknown domain %s\n' "$domain" >&2
    exit 2
    ;;
esac
