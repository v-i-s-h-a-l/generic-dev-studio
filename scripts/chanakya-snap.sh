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
# Parse the master plan's "### Txxx — title" blocks. For each task, extract
# Status, Priority, Complexity, Type, Branch, Released in. Cap at 100 most
# recent (ordered as they appear in the master plan, which is chronological
# enough for snapshot purposes).
produce_briefs() {
  local master="$PROJECT_ROOT/plans/chanakya-master.md"
  if [ ! -f "$master" ]; then
    # Empty-but-valid snapshot — consumers will full-load fallback.
    atomic_write_json "$SNAP_DIR/briefs.json" \
      "$(printf '{"generated_at":"%s","schema":1,"project":"%s","tasks":[],"total":0,"note":"no master plan found"}' \
         "$(now_iso)" "$PROJECT")"
    return $?
  fi

  # awk: walk '### Txxx — …' sections; emit one JSON object per task. Keep
  # each task slim so the active-task array fits under 2KB budget.
  # Status is normalized — trim trailing parenthetical + HTML comment tails,
  # map the canonical vocabulary. Verified/superseded/archived/closed tasks
  # drop out of the `tasks` list entirely (counted in by_status only) —
  # status-mode readers want active work surfaced, not historical ledger.
  local tasks_json
  tasks_json=$(awk -v max=30 '
    function esc(s) {
      gsub(/\\/, "\\\\", s)
      gsub(/"/,  "\\\"", s)
      gsub(/\t/, " ", s)
      return s
    }
    function truncate(s, n) { return (length(s) > n) ? substr(s, 1, n-1) "…" : s }
    function norm_status(s) {
      # Strip HTML comments and trailing parentheticals.
      sub(/ *<!--.*/, "", s)
      sub(/ *\(.*/, "", s)
      sub(/ +$/, "", s)
      # Map first word only to the canonical vocabulary.
      n = split(s, parts, " ")
      w = tolower(parts[1])
      if (w ~ /^(pending|briefed|in-progress|in_progress|done|verified|merged|superseded|blocked|deferred|closed|archived)$/) {
        if (w == "in_progress") return "in-progress"
        return w
      }
      return (w == "" ? "unknown" : w)
    }
    function norm_complexity(s) {
      # First token — XS / S / M / L / XL.
      n = split(s, parts, " ")
      w = parts[1]
      if (w ~ /^(XS|S|M|L|XL)$/) return w
      return ""
    }
    function norm_type(s) {
      n = split(s, parts, " ")
      t = tolower(parts[1])
      sub(/;?$/, "", t); sub(/,$/, "", t)
      return t
    }
    function flush() {
      if (id == "") return
      # Always count (status_all reflects the full project regardless of
      # which tasks are listed below the max cap).
      st = norm_status(status)
      status_all[st]++
      total_all++
      # Historical states do not appear in the active task list.
      if (st == "verified" || st == "superseded" || st == "archived" || st == "closed" || st == "merged") return
      if (count >= max) return
      # Compact shape — drop rarely-used fields (type, branch) from the
      # task objects. Full data available via master-plan fallback.
      printf "%s{\"id\":\"%s\",\"title\":\"%s\",\"status\":\"%s\",\"priority\":\"%s\",\"complexity\":\"%s\"}",
             (count>0?",":""), esc(id), esc(truncate(title, 50)),
             esc(st), esc(priority), esc(norm_complexity(complexity))
      count++
    }
    BEGIN { count=0; id=""; printf "[" }
    /^### [A-Z]+[0-9a-z_-]* — / {
      flush()
      id=""; title=""; status=""; priority=""; complexity=""; type=""; branch=""
      line=$0
      sub(/^### /, "", line)
      p = index(line, " — ")
      if (p > 0) { id = substr(line, 1, p-1); title = substr(line, p+5) }
      else { id = line }
      next
    }
    /^- \*\*Status:\*\*/     { val=$0; sub(/^- \*\*Status:\*\* */, "", val); if (status=="") status=val; next }
    /^- \*\*Priority:\*\*/   { val=$0; sub(/^- \*\*Priority:\*\* */, "", val); if (priority=="") priority=val; next }
    /^- \*\*Complexity:\*\*/ { val=$0; sub(/^- \*\*Complexity:\*\* */, "", val); if (complexity=="") complexity=val; next }
    /^- \*\*Type:\*\*/       { val=$0; sub(/^- \*\*Type:\*\* */, "", val); if (type=="") type=val; next }
    /^- \*\*Branch:\*\*/     { val=$0; sub(/^- \*\*Branch:\*\* */, "", val); if (branch=="") branch=val; next }
    END {
      flush()
      printf "]\n"
      # Second line: by_status aggregate JSON object across ALL tasks.
      printf "{"
      sep=""
      for (s in status_all) {
        printf "%s\"%s\":%d", sep, s, status_all[s]
        sep=","
      }
      printf "}\n"
      # Third line: total_all.
      printf "%d\n", total_all
    }
  ' "$master")
  if [ -z "$tasks_json" ]; then
    tasks_json="[]
{}
0"
  fi

  # awk emits three lines: tasks array, by_status object, total_all int.
  local tasks_only by_status total shown
  local tmp_awk
  tmp_awk=$(mktemp)
  echo "$tasks_json" > "$tmp_awk"
  tasks_only=$(head -n 1 "$tmp_awk")
  by_status=$(head -n 2 "$tmp_awk" | tail -n 1)
  total=$(head -n 3 "$tmp_awk" | tail -n 1)
  rm -f "$tmp_awk"
  [ -z "$by_status" ] && by_status='{}'
  [ -z "$total" ] && total=0

  if ! echo "$tasks_only" | jq empty >/dev/null 2>&1; then
    emit_snap_event snapshot_failed "{\"domain\":\"briefs\",\"error\":\"awk_produced_invalid_json\"}"
    return 1
  fi
  if ! echo "$by_status" | jq empty >/dev/null 2>&1; then
    by_status='{}'
  fi

  shown=$(echo "$tasks_only" | jq length)
  tasks_json="$tasks_only"

  local payload
  payload=$(jq -nc \
    --arg generated_at "$(now_iso)" \
    --arg project "$PROJECT" \
    --argjson tasks "$tasks_json" \
    --argjson by_status "$by_status" \
    --argjson total "$total" \
    --argjson shown "$shown" \
    '{generated_at: $generated_at, schema: 1, project: $project, total: $total, shown: $shown, by_status: $by_status, tasks: $tasks}')

  atomic_write_json "$SNAP_DIR/briefs.json" "$payload"
}

# -----------------------------------------------------------------------------
# Producer: debt
# -----------------------------------------------------------------------------
produce_debt() {
  local master="$PROJECT_ROOT/plans/chanakya-master.md"
  if [ ! -f "$master" ]; then
    atomic_write_json "$SNAP_DIR/debt.json" \
      "$(printf '{"generated_at":"%s","schema":1,"project":"%s","note":"no master plan","build":null,"unit_test":null,"ui_test":null}' \
         "$(now_iso)" "$PROJECT")"
    return $?
  fi

  # Awk: extract the ## Build Debt, ### Unit Test Debt, ### UI Test Debt
  # blocks. We only need Counter, State, and thresholds — the banner
  # decisions are made from these alone.
  local parsed
  parsed=$(awk '
    function emit(section) {
      printf "%s|%s|%s|%s|%s|%s\n", section, counter, warn, block, state, last_green
      counter=""; warn=""; block=""; state=""; last_green=""
    }
    /^## Build Debt/       { if (sec!="") emit(sec); sec="build";     next }
    /^### Unit Test Debt/  { if (sec!="") emit(sec); sec="unit_test"; next }
    /^### UI Test Debt/    { if (sec!="") emit(sec); sec="ui_test";   next }
    /^## Module Index/     { if (sec!="") emit(sec); sec=""; next }
    /^## Test Debt/        { next }  # header only; children set sec
    sec!="" && /^- Counter:/ {
      # "- Counter: 3 / warn@6 / block@12"
      line=$0
      # BSD awk lacks 3-arg match(); use gensub-style capture via sub().
      t=line; sub(/^.*Counter: */, "", t); sub(/ .*$/, "", t); counter=t+0
      t=line; sub(/^.*warn@/, "", t);      sub(/[^0-9].*$/, "", t); warn=t+0
      t=line; sub(/^.*block@/, "", t);     sub(/[^0-9].*$/, "", t); block=t+0
      next
    }
    sec!="" && /^- State:/ {
      line=$0
      sub(/^- State: */, "", line)
      sub(/ *<!--.*/, "", line)
      sub(/ *$/, "", line)
      state=line
      next
    }
    sec!="" && /^- Last green/ {
      line=$0
      sub(/^- Last green[^:]*: */, "", line)
      sub(/ *<!--.*/, "", line)
      sub(/ *$/, "", line)
      last_green=line
      next
    }
    END { if (sec!="") emit(sec) }
  ' "$master")

  # Build per-section JSON via jq. Default empty section to null.
  json_for_section() {
    local sec="$1"
    local line
    line=$(printf '%s\n' "$parsed" | awk -F'|' -v s="$sec" '$1==s {print; exit}')
    if [ -z "$line" ]; then
      printf 'null'
      return
    fi
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

  local build_j unit_j ui_j
  build_j=$(json_for_section build)
  unit_j=$(json_for_section unit_test)
  ui_j=$(json_for_section ui_test)

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
# source project (see _shared/file-locations.md). For a non-gds consumer, we
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
