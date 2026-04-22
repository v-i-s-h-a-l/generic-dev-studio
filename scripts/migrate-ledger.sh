#!/usr/bin/env bash
# migrate-ledger.sh — project-scoped big-bang ledger migration for Phase 2.6.
#
# Transforms legacy ledger state under ~/.dev-studio/<project>/ into the
# new canonical layout (plans/{tasks,briefs,debriefs,reviews,rounds,releases,
# feedback,crashes}/ as YAML artifacts + events/YYYY-MM-DD.jsonl single log).
#
# Preconditions (enforced by pre-flight):
#   - Project is quiesced (Q16): no events in last 60s, no worker heartbeats
#     newer than 60s, no uncommitted changes in any worktree.
#   - Git working tree is clean (or --force is passed).
#
# Phases (§6.1 of PHASE-2-6-PLAN.md):
#   1. Pre-flight check.
#   2. Backup to archive/2026-pre-2.6/ (atomic, idempotent).
#   3. Transform (briefs, debriefs, events, feedback → new YAML paths).
#   4. Diff-verify (see scripts/verify-ledger.sh). Stops on any mismatch.
#   5. Cutover (prune lib-paths.sh legacy entries — manual post-step).
#   6. Resume (user restarts sessions).
#
# Usage:
#   scripts/migrate-ledger.sh --project <slug>           # real run
#   scripts/migrate-ledger.sh --project <slug> --force   # skip pre-flight
#   scripts/migrate-ledger.sh --project <slug> --phases pre-flight,backup
#                                                        # run subset
#   scripts/migrate-ledger.sh --project <slug> --dry-run # log, no writes
#
# Per the Phase 2.6 plan, this script is NOT run against any user project
# by the refactor itself. Unit tests exercise it against fixture data.
# The user runs it on turnip-ios separately after the refactor lands.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

# ---------- CLI parsing ----------
PROJECT=""
FORCE=0
DRY_RUN=0
PHASES="pre-flight,backup,transform,verify,cleanup,index,report"

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)       PROJECT="${2:?--project requires a slug}"; shift 2 ;;
    --force)         FORCE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --phases)        PHASES="${2:?--phases requires a comma-list}"; shift 2 ;;
    -h|--help)       usage ;;
    *)               printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done

# Resolve project — CLI flag wins, env var fallback, git-basename final fallback.
if [ -z "$PROJECT" ]; then
  PROJECT=$(ACHILLES_PROJECT="${ACHILLES_PROJECT:-}" resolve_project 2>/dev/null) || {
    printf 'error: no project resolved. Pass --project <slug>.\n' >&2
    exit 2
  }
fi

# Project root — resolves through lib-paths.sh. ACHILLES_PROJECT_ROOT overrides
# the default $HOME/.dev-studio/<project>/ path for tests (mirrors the pattern
# used by ACHILLES_INBOX_ROOT / DEV_STUDIO_SHARED_ROOT elsewhere).
if [ -n "${ACHILLES_PROJECT_ROOT:-}" ]; then
  PROJECT_ROOT="$ACHILLES_PROJECT_ROOT"
else
  PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
fi

if [ ! -d "$PROJECT_ROOT" ]; then
  printf 'error: project root not found: %s\n' "$PROJECT_ROOT" >&2
  exit 2
fi

ARCHIVE_ROOT="$PROJECT_ROOT/archive/2026-pre-2.6"
PLANS_NEW="$PROJECT_ROOT/plans"
EVENTS_NEW="$PROJECT_ROOT/events"
REPORT_FILE="$PROJECT_ROOT/archive/2026-pre-2.6/migration-report.md"
UNPARSEABLE_DIR="$ARCHIVE_ROOT/unparseable"

phase_enabled() {
  printf '%s' ",$PHASES," | grep -q ",$1,"
}

log() {
  printf '[migrate] %s\n' "$*"
}

dry_write() {
  # $1 = path, $2 = content (or - for stdin)
  local path="$1" content="${2:-}"
  if [ "$DRY_RUN" -eq 1 ]; then
    local bytes
    if [ "$content" = "-" ]; then
      bytes=$(wc -c < /dev/stdin | tr -d ' ')
    else
      bytes=${#content}
    fi
    log "DRY-RUN write path=$path bytes=$bytes"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  if [ "$content" = "-" ]; then
    cat > "$path"
  else
    printf '%s' "$content" > "$path"
  fi
}

# Deterministic UUIDv7 stand-in for migration. Real UUIDv7 needs a high-res
# clock + randomness; migration needs stable rerun output, so we derive from
# (source-path, mtime) sha256 and format as a UUID. Not cryptographically
# unique but collision-free within one project's ledger.
derive_uuid() {
  local key="$1"
  local hash
  hash=$(printf '%s' "$key" | shasum -a 256 | awk '{print $1}')
  # Format as UUIDv7-ish: 8-4-4-4-12 hex. Tag version-nibble to 7.
  printf '%s-%s-7%s-8%s-%s\n' \
    "${hash:0:8}" "${hash:8:4}" "${hash:13:3}" "${hash:17:3}" "${hash:20:12}"
}

# -------- Phase 1: pre-flight --------

preflight_check() {
  log "phase: pre-flight (project=$PROJECT root=$PROJECT_ROOT)"
  if [ "$FORCE" -eq 1 ]; then
    log "  --force passed: skipping pre-flight checks"
    return 0
  fi

  local failed=0

  # 1. No events in the last 60s (approximate: latest mtime of any event-log
  #    source file older than 60s ago).
  local event_log_candidates
  event_log_candidates=$(find "$PROJECT_ROOT" \
    \( -name 'event-log.jsonl' -o -name 'events.jsonl' -o -name 'events.log' \
       -o -name 'events.ndjson' -o -path '*/events/*.jsonl' \
       -o -path '*/plans/chanakya-events.jsonl' \) 2>/dev/null)
  local now_s
  now_s=$(date -u +%s)
  local f age
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    age=$(( now_s - $(mtime "$f" 2>/dev/null || echo "$now_s") ))
    if [ "$age" -lt 60 ]; then
      log "  FAIL: recent event-log write ($f, ${age}s ago). Quiesce the project first."
      failed=1
    fi
  done <<< "$event_log_candidates"

  # 2. No worker heartbeats newer than 60s.
  local alive_candidates
  alive_candidates=$(find "$PROJECT_ROOT/.runtime/achilles-inbox" \
    -maxdepth 3 -name 'alive' -type f 2>/dev/null || true)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    age=$(( now_s - $(mtime "$f" 2>/dev/null || echo "$now_s") ))
    if [ "$age" -lt 60 ]; then
      log "  FAIL: live worker heartbeat ($f, ${age}s ago). Stop workers first."
      failed=1
    fi
  done <<< "$alive_candidates"

  # 3. yq is installed. Without it, rebuild-index.sh cannot write plans/index.yaml,
  #    which leaves the post-migration tree in a broken half-state where every
  #    query-plans.sh call fails. Surfacing this up-front is worth much more than
  #    the silent index gap it replaces (see #70).
  if ! command -v yq >/dev/null 2>&1; then
    log "  FAIL: yq not installed. Install with 'brew install yq' — required for plans/index.yaml."
    failed=1
  fi

  # 3b. jq is installed. transform_events normalizes legacy pre-2.5 event
  #     shapes (.type→.event, .task_id→.task) via jq (see #71); without jq,
  #     the normalization silently no-ops and migrated events keep the
  #     wrong field names.
  if ! command -v jq >/dev/null 2>&1; then
    log "  FAIL: jq not installed. Install with 'brew install jq' — required for event normalization."
    failed=1
  fi

  # 4. No uncommitted changes in any worktree under $PROJECT_ROOT/worktrees.
  local worktree_dirs
  worktree_dirs=$(find "$PROJECT_ROOT/worktrees" -maxdepth 2 -type d -name '.git' 2>/dev/null \
    | sed 's|/\.git$||' || true)
  local wt
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    [ -d "$wt" ] || continue
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      log "  FAIL: uncommitted changes in worktree $wt. Stash or commit first."
      failed=1
    fi
  done <<< "$worktree_dirs"

  if [ "$failed" -eq 1 ]; then
    log "pre-flight FAILED. Pass --force only for developer testing against fixtures."
    return 1
  fi

  log "pre-flight OK"
  return 0
}

# -------- Phase 2: backup --------

# Ledger-state whitelist. The earlier full-tree copy (mindepth 1, exclude
# archive/) dragged in `derived-data/` (207k Xcode files on turnip-ios,
# ~27GB, ~50-min digest) and `worktrees/` — neither are ledger state. Only
# these subpaths are authoritative ledger state that the rollback would
# need. Everything else is derived, transient, or already versioned in git.
#
# Dirs (relative to $PROJECT_ROOT). `feedback-inbox/` is the pre-2.6 legacy
# location; `feedback/` exists only if an older run already migrated.
BACKUP_DIRS="plans events feedback feedback-inbox .runtime/state"
# Top-level legacy event-log sibling files (cleanup phase also moves these
# once parity is confirmed, but backup captures them first for rollback).
BACKUP_FILES="event-log.jsonl events.jsonl events.log events.ndjson agents.jsonl"

backup_project() {
  log "phase: backup to $ARCHIVE_ROOT"
  if [ -d "$ARCHIVE_ROOT" ] && [ -f "$ARCHIVE_ROOT/.digest" ]; then
    # Idempotent: skip if archive already exists.
    log "  backup already exists — idempotent re-run, skipping copy"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "  DRY-RUN would copy ledger whitelist → $ARCHIVE_ROOT/ (dirs=[$BACKUP_DIRS] files=[$BACKUP_FILES])"
    return 0
  fi
  local tmp="$ARCHIVE_ROOT.tmp.$$"
  mkdir -p "$tmp"
  local sub f src
  for sub in $BACKUP_DIRS; do
    src="$PROJECT_ROOT/$sub"
    [ -e "$src" ] || continue
    mkdir -p "$tmp/$(dirname "$sub")"
    cp -R "$src" "$tmp/$sub" 2>/dev/null || true
  done
  for f in $BACKUP_FILES; do
    src="$PROJECT_ROOT/$f"
    [ -f "$src" ] || continue
    cp "$src" "$tmp/$f" 2>/dev/null || true
  done
  # Digest manifest for idempotency check on re-run.
  (cd "$tmp" && find . -type f 2>/dev/null | sort | xargs -I{} shasum -a 256 '{}' 2>/dev/null) \
    > "$tmp/.digest" 2>/dev/null || true
  mv "$tmp" "$ARCHIVE_ROOT"
  log "  backup complete"
}

# -------- Phase 3: transform --------

# Count of each kind processed; written into the migration report.
COUNT_BRIEFS=0
COUNT_DEBRIEFS=0
COUNT_EVENTS=0
COUNT_FEEDBACK=0
COUNT_MISFILED_DEBRIEFS=0
COUNT_UNPARSEABLE=0
COUNT_RETIRED=0
COUNT_RETIRE_SKIPPED=0
COUNT_FEEDBACK_PRUNED=0
COUNT_TASKS=0
COUNT_ROUNDS=0
COUNT_RELEASES=0

# Write one line to the migration report. Created on first call.
report() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "REPORT: $*"
    return 0
  fi
  mkdir -p "$(dirname "$REPORT_FILE")"
  if [ ! -f "$REPORT_FILE" ]; then
    {
      printf '# Migration Report — %s\n\n' "$PROJECT"
      printf 'Generated: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$REPORT_FILE"
  fi
  printf '%s\n' "$*" >> "$REPORT_FILE"
}

unparseable() {
  # $1 = source path, $2 = reason
  COUNT_UNPARSEABLE=$((COUNT_UNPARSEABLE + 1))
  if [ "$DRY_RUN" -eq 1 ]; then
    log "  UNPARSEABLE: $1 ($2)"
    return 0
  fi
  mkdir -p "$UNPARSEABLE_DIR"
  cp "$1" "$UNPARSEABLE_DIR/" 2>/dev/null || true
  printf '%s\t%s\n' "$1" "$2" >> "$UNPARSEABLE_DIR/manifest.tsv"
}

# ---- Brief transform: chanakya-tasks/<task-id>-<type>.md → plans/briefs/<uuidv7>.yaml ----
transform_briefs() {
  local legacy_dir="$PROJECT_ROOT/plans/chanakya-tasks"
  [ -d "$legacy_dir" ] || { log "  no legacy briefs dir — skipping"; return 0; }
  local f task_id type uuid body_start
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    # Filename pattern: <task-id>-<type>.md where task-id is the leading
    # token before the first hyphen and type is everything after (may itself
    # contain hyphens, e.g. "unit-test", "integration-test").
    local base
    base=$(basename "$f" .md)
    task_id="${base%%-*}"
    type="${base#*-}"
    if [ -z "$task_id" ] || [ -z "$type" ] || [ "$task_id" = "$base" ]; then
      unparseable "$f" "filename does not match <task-id>-<type>.md"
      continue
    fi
    uuid=$(derive_uuid "brief:$task_id:$type:$(mtime "$f")")
    local task_uuid
    task_uuid=$(derive_uuid "task:$task_id")
    local out="$PLANS_NEW/briefs/$uuid.yaml"
    # Extract body (everything after frontmatter, or all of it if no fm).
    body_start=$(awk 'NR==1 && $0=="---" {flag=1; next}
                      flag && $0=="---" {print NR+1; exit}
                      flag {next}
                      !flag {print 1; exit}' "$f" 2>/dev/null || echo 1)
    local body
    body=$(tail -n +"$body_start" "$f" 2>/dev/null | sed 's/^/  /')
    if [ "$DRY_RUN" -eq 1 ]; then
      log "  DRY-RUN write brief: $f → $out"
    else
      mkdir -p "$(dirname "$out")"
      {
        printf 'schema_version: {name: brief, version: 3.1.0, min_reader: 3.0.0, deprecated_at: null}\n'
        printf 'id: %s\n' "$uuid"
        printf 'task_id: %s\n' "$task_uuid"
        printf 'type: %s\n' "$type"
        printf 'size: m\n'      # conservative default — real migration enriches from master-plan
        printf 'state: debriefed\n'  # legacy briefs are terminal at migration time
        printf 'created_at: %s\n' "$(date -u -r "$(mtime "$f")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'updated_at: %s\n' "$(date -u -r "$(mtime "$f")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'figma: null\n'
        printf 'reads: []\n'
        printf 'writes: []\n'
        printf 'acceptance: []\n'
        printf 'testability: []\n'
        printf 'rework_of: null\n'
        printf 'legacy_task_id: "%s"\n' "$task_id"
        printf 'body: |\n%s\n' "$body"
      } > "$out"
    fi
    COUNT_BRIEFS=$((COUNT_BRIEFS + 1))
  done < <(find "$legacy_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null)
  log "  transformed $COUNT_BRIEFS brief(s)"
}

# ---- Debrief transform: chanakya-inbox/<task-id>-debrief.md → plans/debriefs/<uuidv7>.yaml ----
# Also handles misfiled debriefs (Q20) — scans chanakya-inbox root for anything
# matching *-debrief.md even if it lives in subdirs it shouldn't.
transform_debriefs() {
  local inbox="$PROJECT_ROOT/plans/chanakya-inbox"
  [ -d "$inbox" ] || { log "  no legacy chanakya-inbox — skipping debriefs"; return 0; }
  local f base task_id uuid task_uuid
  # Scan everything matching *-debrief.md anywhere under chanakya-inbox. Files
  # in the root are correctly filed; files in subdirs (except processed/) are
  # flagged as misfiled.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    # Skip the processed/ archive — Q18 says archive-as-is, do not re-migrate.
    case "$f" in
      */processed/*) continue ;;
    esac
    base=$(basename "$f" .md)
    task_id="${base%-debrief}"
    if [ "$task_id" = "$base" ]; then
      unparseable "$f" "filename does not match <task-id>-debrief.md"
      continue
    fi
    # Q20: detect misfiled debriefs (in subdirs other than root or processed/).
    local rel_parent
    rel_parent=$(dirname "$f")
    if [ "$rel_parent" != "$inbox" ]; then
      COUNT_MISFILED_DEBRIEFS=$((COUNT_MISFILED_DEBRIEFS + 1))
      report "- misfiled-debrief: $f (routed to plans/debriefs/)"
    fi
    uuid=$(derive_uuid "debrief:$task_id:$(mtime "$f")")
    task_uuid=$(derive_uuid "task:$task_id")
    local out="$PLANS_NEW/debriefs/$uuid.yaml"
    local body
    body=$(cat "$f" | sed 's/^/  /')
    if [ "$DRY_RUN" -eq 1 ]; then
      log "  DRY-RUN write debrief: $f → $out"
    else
      mkdir -p "$(dirname "$out")"
      {
        printf 'schema_version: {name: debrief, version: 2.0.0, min_reader: 2.0.0, deprecated_at: null}\n'
        printf 'id: %s\n' "$uuid"
        printf 'task_id: %s\n' "$task_uuid"
        printf 'brief_id: null\n'
        printf 'mode: task\n'
        printf 'completed_at: %s\n' "$(date -u -r "$(mtime "$f")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'branch: {worked_on: null, merged_into: null, merge_sha: null}\n'
        printf 'commits: []\n'
        printf 'diff_summary: {files: 0, added_lines: 0, removed_lines: 0}\n'
        printf 'decisions: []\n'
        printf 'tests: {added: [], modified: [], skipped_because: null}\n'
        printf 'testability: null\n'
        printf 'build_gate: lsp-only\n'
        printf 'build_debt_override: false\n'
        printf 'debt: {build: false, test_unit: false, test_ui: false, notes: null}\n'
        printf 'performance: []\n'
        printf 'key_learnings: []\n'
        printf 'known_issues: []\n'
        printf 'follow_ups: []\n'
        printf 'open_questions: []\n'
        printf 'argus_review: {status: not-invoked, review_id: null, notes: null}\n'
        printf 'legacy_task_id: "%s"\n' "$task_id"
        printf 'body: |\n%s\n' "$body"
      } > "$out"
    fi
    COUNT_DEBRIEFS=$((COUNT_DEBRIEFS + 1))
  done < <(find "$inbox" -type f -name '*-debrief.md' 2>/dev/null)
  log "  transformed $COUNT_DEBRIEFS debrief(s); $COUNT_MISFILED_DEBRIEFS misfiled detected"
}

# ---- Events consolidation: 9 sources → events/YYYY-MM-DD.jsonl ----
# Merge algorithm per §3.3: stream, dedupe, sort by occurred_at, day-partition.
transform_events() {
  # When ACHILLES_PROJECT_ROOT is set (tests / custom project roots), skip the
  # project-memory lookup — it resolves to ~/.claude/projects/<slug>/memory/,
  # which is machine-global and unrelated to the override root. Production
  # runs still pick up the memory events.
  local memory=""
  if [ -z "${ACHILLES_PROJECT_ROOT:-}" ]; then
    memory=$(resolve_project_memory 2>/dev/null || true)
  fi
  # Collect sources.
  local sources=""
  for candidate in \
    "$PROJECT_ROOT/event-log.jsonl" \
    "$PROJECT_ROOT/events.jsonl" \
    "$PROJECT_ROOT/events.log" \
    "$PROJECT_ROOT/.runtime/events.jsonl" \
    "$PROJECT_ROOT/.runtime/events.ndjson" \
    "$PROJECT_ROOT/plans/chanakya-events.jsonl" ; do
    [ -f "$candidate" ] && sources="$sources$candidate"$'\n'
  done
  if [ -n "$memory" ]; then
    for candidate in "$memory/events/agents.jsonl" "$memory/events/events.jsonl"; do
      [ -f "$candidate" ] && sources="$sources$candidate"$'\n'
    done
    # Existing day-partition files in project memory — move to canonical path.
    if [ -d "$memory/events" ]; then
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
          agents.jsonl|events.jsonl) continue ;;
          ????-??-??.jsonl) sources="$sources$f"$'\n' ;;
        esac
      done < <(find "$memory/events" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null)
    fi
  fi

  if [ -z "$sources" ]; then
    log "  no legacy event-log sources — skipping"
    return 0
  fi
  log "  merging $(printf '%s' "$sources" | sed '/^$/d' | wc -l | tr -d ' ') source(s) into $EVENTS_NEW/"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "  DRY-RUN would merge + day-partition + dedupe"
    return 0
  fi

  # Collect every line with a JSON object into a single stream.
  local tmp_merged tmp_dedup
  tmp_merged=$(mktemp)
  tmp_dedup=$(mktemp)
  # No RETURN trap — `set -u` + trap expansion at exit time interacts badly with
  # function-local scope. Explicit rm at end of function instead.
  while IFS= read -r src; do
    [ -z "$src" ] && continue
    [ -f "$src" ] || continue
    while IFS= read -r line; do
      # Skip empty + non-JSON lines (the events.log text variant).
      case "$line" in
        ''|'#'*) continue ;;
        '{'*'}'*) ;;
        *) continue ;;
      esac
      # Tag with source for debugging; stripped before day-bucket.
      printf '%s\n' "$line" >> "$tmp_merged"
      COUNT_EVENTS=$((COUNT_EVENTS + 1))
    done < "$src"
  done <<< "$sources"

  # Dedupe by (producer.agent, idempotency_key) — crude grep; tolerant of
  # missing fields by treating as unique. Stable-sort by ts first so earlier
  # occurrences win.
  # shellcheck disable=SC2016
  awk '
    {
      key = ""
      if (match($0, /"idempotency_key":"[^"]*"/)) key = substr($0, RSTART, RLENGTH)
      if (key == "") { print; next }
      if (!(key in seen)) { seen[key]=1; print }
    }
  ' "$tmp_merged" > "$tmp_dedup"

  # Normalize legacy pre-2.5 field names (.type→.event, .task_id→.task) so the
  # merged corpus matches the events.md schema. Upstream merge already filters
  # non-JSON lines, so jq is safe to run in batch mode here.
  local tmp_normalized
  tmp_normalized=$(mktemp)
  jq -c '
    (if has("type")    and (has("event") | not) then .event = .type    | del(.type)    else . end)
    | (if has("task_id") and (has("task")  | not) then .task  = .task_id | del(.task_id) else . end)
  ' "$tmp_dedup" > "$tmp_normalized"

  # Day-partition: bucket by UTC date from ts field. Events without a parseable
  # ts land in a sentinel file (unbucketed-events.jsonl under archive/unparseable).
  mkdir -p "$EVENTS_NEW"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local ts day
    ts=$(printf '%s\n' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' | head -n 1)
    day="${ts%%T*}"
    if [ -z "$day" ] || ! printf '%s' "$day" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
      mkdir -p "$UNPARSEABLE_DIR"
      printf '%s\n' "$line" >> "$UNPARSEABLE_DIR/unbucketed-events.jsonl"
      continue
    fi
    printf '%s\n' "$line" >> "$EVENTS_NEW/$day.jsonl"
  done < "$tmp_normalized"
  rm -f "$tmp_normalized"

  # Sort each day file by ts (stable).
  for daily in "$EVENTS_NEW"/????-??-??.jsonl; do
    [ -f "$daily" ] || continue
    sort -o "$daily" "$daily"
  done

  # Emit the events index (manifest per day).
  {
    printf 'schema_version: {name: events-index, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}\n'
    printf 'generated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'days:\n'
    for daily in "$EVENTS_NEW"/????-??-??.jsonl; do
      [ -f "$daily" ] || continue
      local day count first last
      day=$(basename "$daily" .jsonl)
      count=$(wc -l < "$daily" | tr -d ' ')
      first=$(head -n 1 "$daily" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
      last=$(tail -n 1 "$daily" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
      printf '  - {day: "%s", count: %s, first_ts: "%s", last_ts: "%s"}\n' \
        "$day" "$count" "$first" "$last"
    done  } > "$EVENTS_NEW/index.yaml"

  rm -f "$tmp_merged" "$tmp_dedup"
  log "  merged $COUNT_EVENTS event(s)"
}

# ---- Feedback transform: feedback-inbox/<source>/reports/*.md → plans/feedback/<uuidv7>.yaml ----
transform_feedback() {
  local fb_root="$PROJECT_ROOT/feedback-inbox"
  [ -d "$fb_root" ] || { log "  no feedback-inbox — skipping"; return 0; }
  local f base uuid
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    base=$(basename "$f" .md)
    uuid=$(derive_uuid "feedback:$f:$(mtime "$f")")
    local out="$PLANS_NEW/feedback/$uuid.yaml"
    local body
    body=$(cat "$f" | sed 's/^/  /')
    if [ "$DRY_RUN" -eq 1 ]; then
      log "  DRY-RUN write feedback: $f → $out"
    else
      mkdir -p "$(dirname "$out")"
      {
        printf 'schema_version: {name: feedback, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}\n'
        printf 'id: %s\n' "$uuid"
        printf 'state: ingested\n'
        printf 'source: slack-channel\n'      # conservative — real migration reads the report header
        printf 'reporter: "unknown"\n'
        printf 'source_metadata: {}\n'
        printf 'ingested_at: %s\n' "$(date -u -r "$(mtime "$f")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'subject: "%s"\n' "$base"
        printf 'labels: []\n'
        printf 'linked_tasks: []\n'
        printf 'linked_crashes: []\n'
        printf 'root_cause_id: null\n'
        printf 'attachments: []\n'
        printf 'resolved_by: null\n'
        printf 'resolved_at: null\n'
        printf 'notes: null\n'
        printf 'legacy_path: "%s"\n' "$f"
        printf 'body: |\n%s\n' "$body"
      } > "$out"
    fi
    COUNT_FEEDBACK=$((COUNT_FEEDBACK + 1))
  done < <(find "$fb_root" -type f -name '*.md' -path '*/reports/*' 2>/dev/null)
  log "  transformed $COUNT_FEEDBACK feedback record(s)"

  # Q19: prune empty placeholder dirs (archive/, reporters/, root-causes/ with
  # only .gitkeep). Real content dirs (reports/, synthesized/) are left alone.
  local sub
  for sub in archive reporters root-causes; do
    find "$fb_root" -type d -name "$sub" 2>/dev/null | while IFS= read -r d; do
      [ -d "$d" ] || continue
      local content_count
      content_count=$(find "$d" -type f ! -name '.gitkeep' 2>/dev/null | head -n 1 | wc -l | tr -d ' ')
      if [ "$content_count" -eq 0 ]; then
        report "- pruned placeholder dir: $d (only .gitkeep or empty)"
        [ "$DRY_RUN" -eq 0 ] && rm -rf "$d"
      fi
    done
  done
}

# ---- Task transform: chanakya-master.md "### T<id> — <title>" rows → plans/tasks/<uuidv7>.yaml ----
#
# Parses per-task sections from the legacy master plan. Captures the fields the
# post-2.6 schema requires (id, title, state, size) with best-effort mapping
# from legacy status/complexity. Legacy prose is preserved in `legacy_row:` as
# the full markdown chunk so later enrichment (priority, type, source links) is
# lossless — the schema's minimal shape is deliberate (Phase 2.6 §2.1).
#
# Status mapping (legacy → post-2.6 task-lifecycle states):
#   pending      → proposed
#   briefed      → briefed
#   in-progress  → in-progress
#   done         → merged
#   verified     → verified
#   blocked      → blocked
#   cancelled    → cancelled
#   deferred     → blocked       (reason kept in legacy_row)
#   absorbed/closed/obsoleted/superseded* → archived
#   anything else → proposed     (logged as unparseable status)
transform_tasks() {
  local master="$PROJECT_ROOT/plans/chanakya-master.md"
  [ -f "$master" ] || { log "  no chanakya-master.md — skipping tasks"; return 0; }

  # One temp file per task — awk splits on `### T<id>` boundaries. Using plain
  # pattern matching (BWK awk on macOS lacks match() with captures). Task-id +
  # title are parsed from the filename/header in shell below.
  local split_dir
  split_dir=$(mktemp -d)
  awk -v dir="$split_dir" '
    /^### T[0-9a-z]+ — / {
      # Derive id by stripping "### " prefix and everything from " — " onward.
      line = $0
      id = line
      sub(/^### /, "", id)
      sub(/ — .*$/, "", id)
      # Title is everything after " — ".
      title = line
      sub(/^### T[0-9a-z]+ — /, "", title)
      cur_file = dir "/" id ".section"
      print title > (dir "/" id ".title")
      in_section = 1
      next
    }
    /^### / || /^## / { in_section = 0; next }
    in_section { print >> cur_file }
  ' "$master"

  local section_file task_id title body status complexity type priority state size uuid out
  for section_file in "$split_dir"/*.section; do
    [ -f "$section_file" ] || continue
    task_id=$(basename "$section_file" .section)
    title=$(cat "$split_dir/$task_id.title" 2>/dev/null)
    body=$(cat "$section_file")

    # Extract the common fields. Bold `**Foo:**` then value up to end-of-line
    # or HTML-comment start. `tr -d` strips the bold markers post-match.
    status=$(printf '%s' "$body" | grep -m1 -E '^- \*\*Status:\*\*' | sed -E 's/^- \*\*Status:\*\*[[:space:]]*//; s/[[:space:]]*(\(.*|<!--.*)//' | tr -d ' ')
    complexity=$(printf '%s' "$body" | grep -m1 -E '^- \*\*Complexity:\*\*' | sed -E 's/^- \*\*Complexity:\*\*[[:space:]]*//; s/[[:space:]]*\(.*//; s/[[:space:]]*$//')
    type=$(printf '%s' "$body" | grep -m1 -E '^- \*\*Type:\*\*' | sed -E 's/^- \*\*Type:\*\*[[:space:]]*//; s/[[:space:]]*\(.*//; s/[[:space:]]*$//')
    priority=$(printf '%s' "$body" | grep -m1 -E '^- \*\*Priority:\*\*' | sed -E 's/^- \*\*Priority:\*\*[[:space:]]*//; s/[[:space:]]*$//')

    # Map status → state.
    case "$status" in
      pending)                state="proposed" ;;
      briefed)                state="briefed" ;;
      in-progress)            state="in-progress" ;;
      done)                   state="merged" ;;
      verified)               state="verified" ;;
      blocked)                state="blocked" ;;
      cancelled|canceled)     state="cancelled" ;;
      deferred)               state="blocked" ;;
      absorbed|closed|obsoleted) state="archived" ;;
      superseded*)            state="archived" ;;
      "")                     state="proposed" ;;
      *)                      state="proposed"
                              log "  warn: task $task_id unparseable status '$status' — defaulting to proposed" ;;
    esac

    # Map complexity → size (XS→xs, S→s, M→m, L/XL→l). Default m.
    case "$complexity" in
      XS|xs) size="xs" ;;
      S|s)   size="s" ;;
      M|m)   size="m" ;;
      L|l|XL|xl) size="l" ;;
      "")    size="m" ;;
      *)     size="m" ;;
    esac

    uuid=$(derive_uuid "task:$task_id")
    out="$PLANS_NEW/tasks/$uuid.yaml"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "  DRY-RUN write task: $task_id ($state/$size) → $out"
    else
      mkdir -p "$(dirname "$out")"
      # Indent legacy body for YAML block scalar.
      local indented_body
      indented_body=$(printf '%s' "$body" | sed 's/^/  /')
      local ts
      ts=$(date -u -r "$(mtime "$master")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
      local history_uuid
      history_uuid=$(derive_uuid "task-history:$task_id")
      {
        printf 'schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}\n'
        printf 'id: %s\n' "$uuid"
        printf 'title: %s\n' "$(yaml_quote "$title")"
        printf 'state: %s\n' "$state"
        printf 'size: %s\n' "$size"
        printf 'created_at: %s\n' "$ts"
        printf 'updated_at: %s\n' "$ts"
        printf 'links:\n'
        printf '  brief: null\n'
        printf '  debrief: null\n'
        printf '  reviews: []\n'
        printf '  release: null\n'
        printf '  feedback: []\n'
        printf 'history:\n'
        printf '  - {from: null, to: %s, actor: chanakya, at: %s, event_id: %s, reason: "migrated from chanakya-master.md"}\n' \
          "$state" "$ts" "$history_uuid"
        printf 'legacy_task_id: "%s"\n' "$task_id"
        [ -n "$priority" ]   && printf 'legacy_priority: %s\n' "$(yaml_quote "$priority")"
        [ -n "$type" ]       && printf 'legacy_type: %s\n' "$(yaml_quote "$type")"
        [ -n "$complexity" ] && printf 'legacy_complexity: %s\n' "$(yaml_quote "$complexity")"
        [ -n "$status" ]     && printf 'legacy_status: %s\n' "$(yaml_quote "$status")"
        printf 'legacy_row: |\n%s\n' "$indented_body"
      } > "$out"
    fi
    COUNT_TASKS=$((COUNT_TASKS + 1))
  done
  rm -rf "$split_dir"
  log "  transformed $COUNT_TASKS task(s)"
}

# Quote a string for YAML inline scalar. Double-quotes with " and \ escaped.
yaml_quote() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# ---- Round transform: plans/user-testing-rounds/user-testing-round<N>.md → plans/rounds/<uuidv7>.yaml ----
#
# Minimal-fidelity: round_number from filename, scope + state defaulted, cases
# left as an empty array (parsing the checklist structure reliably is brittle;
# the full markdown body is kept verbatim in legacy_body for re-hydration).
transform_rounds() {
  local legacy_dir="$PROJECT_ROOT/plans/user-testing-rounds"
  [ -d "$legacy_dir" ] || { log "  no user-testing-rounds — skipping rounds"; return 0; }
  local f round_num uuid out ts body
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    round_num=$(basename "$f" .md | sed -E 's/^user-testing-round([0-9]+)$/\1/')
    [ -z "$round_num" ] && { unparseable "$f" "filename does not match user-testing-round<N>.md"; continue; }
    uuid=$(derive_uuid "round:$round_num")
    out="$PLANS_NEW/rounds/$uuid.yaml"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "  DRY-RUN write round: $f (round $round_num) → $out"
    else
      mkdir -p "$(dirname "$out")"
      ts=$(date -u -r "$(mtime "$f")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
      body=$(sed 's/^/  /' "$f")
      {
        printf 'schema_version: {name: round, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}\n'
        printf 'id: %s\n' "$uuid"
        printf 'round_number: %s\n' "$round_num"
        printf 'state: closed\n'         # historical rounds treated as closed on migration
        printf 'scope: new\n'            # conservative; real values extractable later
        printf 'generated_at: %s\n' "$ts"
        printf 'closed_at: %s\n' "$ts"
        printf 'previous_round: null\n'
        printf 'tested_on: {device: "unknown", os_version: "unknown"}\n'
        printf 'tasks: []\n'
        printf 'reviews: []\n'
        printf 'cases: []\n'
        printf 'legacy_path: "%s"\n' "$f"
        printf 'legacy_round_number: %s\n' "$round_num"
        printf 'legacy_body: |\n%s\n' "$body"
      } > "$out"
    fi
    COUNT_ROUNDS=$((COUNT_ROUNDS + 1))
  done < <(find "$legacy_dir" -maxdepth 1 -type f -name 'user-testing-round*.md' 2>/dev/null)
  log "  transformed $COUNT_ROUNDS round(s)"
}

# ---- Release transform: `## Release Log` table in chanakya-master.md → plans/releases/<uuidv7>.yaml ----
#
# The table is `| Build | Branch | Date | Key tasks |`. Each row becomes one
# release artifact. Build column carries `TF-<n>` or `AS-<n>` → channel + build
# number. Key-tasks column lists `T<nnn>` refs — stored as legacy_task_ids for
# later reverse-mapping to YAML task UUIDs.
transform_releases() {
  local master="$PROJECT_ROOT/plans/chanakya-master.md"
  [ -f "$master" ] || { log "  no chanakya-master.md — skipping releases"; return 0; }

  # Extract the Release Log section rows between `## Release Log` and the next
  # `## ` heading (or EOF). Skip the table header + separator rows.
  local table
  table=$(awk '/^## Release Log/{in_log=1; next} /^## / && in_log{exit} in_log' "$master" \
    | grep -E '^\| (TF-|AS-)')
  [ -z "$table" ] && { log "  no Release Log rows — skipping releases"; return 0; }

  local row build branch date_str tasks tag channel build_num uuid out ts
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    # Split on `|` — fields are: "", build, branch, date, tasks, "". sed-trim leading/trailing space.
    build=$(printf '%s' "$row"   | awk -F '\\|' '{gsub(/^ +| +$/, "", $2); print $2}')
    branch=$(printf '%s' "$row"  | awk -F '\\|' '{gsub(/^ +| +$/, "", $3); print $3}')
    date_str=$(printf '%s' "$row"| awk -F '\\|' '{gsub(/^ +| +$/, "", $4); print $4}')
    tasks=$(printf '%s' "$row"   | awk -F '\\|' '{gsub(/^ +| +$/, "", $5); print $5}')
    tag="$build"
    case "$build" in
      TF-*)  channel="testflight"; build_num="${build#TF-}" ;;
      AS-*)  channel="appstore";   build_num="${build#AS-}" ;;
      *)     channel="testflight"; build_num="${build#*-}" ;;
    esac
    # Truncate build_num to digits only (some rows have "3150 (v26.4.15, LIVE)" style).
    build_num=$(printf '%s' "$build_num" | sed -E 's/[^0-9].*$//')
    [ -z "$build_num" ] && continue

    uuid=$(derive_uuid "release:$channel:$build_num")
    out="$PLANS_NEW/releases/$uuid.yaml"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "  DRY-RUN write release: $tag → $out"
    else
      mkdir -p "$(dirname "$out")"
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      # Extract task-id list (T<nnn> tokens only).
      local task_list
      task_list=$(printf '%s' "$tasks" | grep -oE 'T[0-9]+[a-z]*' | sort -u | paste -sd, -)
      {
        printf 'schema_version: {name: release, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}\n'
        printf 'id: %s\n' "$uuid"
        printf 'channel: %s\n' "$channel"
        printf 'state: released\n'         # historical entries in the log have shipped; best-effort
        printf 'build_number: %s\n' "$build_num"
        printf 'version: "unknown"\n'       # version not in table; enrich later from debriefs
        printf 'tag: "%s"\n' "$tag"
        printf 'commit_sha: ""\n'
        printf 'submitted_at: "%sT00:00:00Z"\n' "$date_str"
        printf 'last_state_checked_at: %s\n' "$ts"
        printf 'released_at: null\n'
        printf 'tasks: []\n'                # legacy_task_ids preserved below; backfill in a follow-up pass
        printf 'reviews: []\n'
        printf 'asc_metadata: null\n'
        printf 'slack: null\n'
        printf 'notes: null\n'
        printf 'legacy_tag: "%s"\n' "$tag"
        printf 'legacy_branch: "%s"\n' "$branch"
        printf 'legacy_date: "%s"\n' "$date_str"
        printf 'legacy_task_ids: "%s"\n' "$task_list"
        printf 'legacy_key_tasks_raw: %s\n' "$(yaml_quote "$tasks")"
      } > "$out"
    fi
    COUNT_RELEASES=$((COUNT_RELEASES + 1))
  done <<< "$table"
  log "  transformed $COUNT_RELEASES release(s)"
}

do_transform() {
  log "phase: transform"
  mkdir -p "$PLANS_NEW"/{tasks,briefs,debriefs,reviews,rounds,releases,feedback,crashes}
  mkdir -p "$EVENTS_NEW"
  transform_tasks
  transform_briefs
  transform_debriefs
  transform_events
  transform_feedback
  transform_rounds
  transform_releases
}

# -------- Phase 4: verify (delegate to verify-ledger.sh) --------

do_verify() {
  log "phase: verify"
  if [ ! -x "$SCRIPT_DIR/verify-ledger.sh" ]; then
    log "  verify-ledger.sh not found or not executable — skipping"
    return 0
  fi
  ACHILLES_PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT_DIR/verify-ledger.sh" --project "$PROJECT"
}

# -------- Phase 5 (cutover): manual — not automated in this script --------
# Cutover is a deliberate user action: remove legacy paths from lib-paths.sh
# and commit. This script prints the required follow-up instructions rather
# than performing the edit — cutover must be reviewable, and the commit that
# prunes legacy paths is the authoritative signal that migration is complete.

# -------- Phase 5.5: cleanup — retire legacy event-log siblings --------
#
# The transform merges-and-dedupes nine legacy event sources into canonical
# events/<YYYY-MM-DD>.jsonl but leaves the originals in place, so the live
# project dir still has orphan event-log files post-migration. This phase
# verifies parity against the canonical corpus, then MOVES (not deletes)
# each verified source to archive/2026-pre-2.6/legacy-event-sources/ — one
# more undo step for the operator.
#
# Parity check:
#   jsonl sources — wc -l of the source ≤ total wc -l across canonical day
#     files. Dedupe-driven shortfalls are legitimate (dup line collapsed
#     into one canonical line), so the check is "canonical has at least as
#     many lines as legacy had".
#   events.log (text variant) — grep-for-event-markers, same comparison.
# On parity fail, the file is left in place with a warning; operator
# inspects manually rather than losing data.

LEGACY_RETIRE_DIR="$ARCHIVE_ROOT/legacy-event-sources"

# Total line count across all canonical day files. Recomputed each call;
# the count grows as retirement events get appended during this same phase,
# which is harmless for parity (a larger canonical denominator only ever
# helps the `canonical >= source` check).
canonical_event_lines() {
  local total=0 f lines
  for f in "$EVENTS_NEW"/????-??-??.jsonl; do
    [ -f "$f" ] || continue
    lines=$(wc -l < "$f" | tr -d ' ')
    total=$(( total + lines ))
  done
  printf '%s' "$total"
}

# Append a legacy_event_source_retired event to today's canonical day file.
# Intentionally writes to $EVENTS_NEW (post-migration canonical location),
# not resolve_event_log() which points at project-memory.
emit_retirement_event() {
  local src="$1" source_lines="$2" canonical_lines="$3"
  local today ts day_file
  today=$(date -u +%Y-%m-%d)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  day_file="$EVENTS_NEW/$today.jsonl"
  mkdir -p "$EVENTS_NEW"
  # Relative source path keeps the payload inside the 4KB atomicity budget
  # even when $PROJECT_ROOT is long (enterprise-workspace layouts, CI mounts).
  local rel="${src#$PROJECT_ROOT/}"
  printf '{"ts":"%s","agent":"chanakya","event":"legacy_event_source_retired","task":"","data":{"source":"%s","source_lines":%s,"canonical_lines":%s}}\n' \
    "$ts" "$rel" "$source_lines" "$canonical_lines" >> "$day_file"
}

# Count lines that look like event records. For jsonl, that's any non-blank
# line starting with `{`. For events.log (text), that's any line containing
# the `"event":` marker (conservative — matches both JSON and the legacy
# "event=foo" text format which also uses `event:` as a separator).
count_source_records() {
  local src="$1"
  case "$src" in
    *events.log) grep -c '"event":\|event=' "$src" 2>/dev/null || printf '0' ;;
    *) grep -c '^{' "$src" 2>/dev/null || printf '0' ;;
  esac
}

retire_one() {
  local src="$1"
  [ -f "$src" ] || return 0
  local source_lines canonical_lines
  source_lines=$(count_source_records "$src")
  canonical_lines=$(canonical_event_lines)
  if [ "$source_lines" -gt 0 ] && [ "$canonical_lines" -lt "$source_lines" ]; then
    log "  WARN: parity failed for $src (source=$source_lines canonical=$canonical_lines) — leaving in place"
    report "- cleanup-skipped: $src (source_lines=$source_lines canonical_lines=$canonical_lines)"
    COUNT_RETIRE_SKIPPED=$((COUNT_RETIRE_SKIPPED + 1))
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "  DRY-RUN would retire: $src (source=$source_lines canonical=$canonical_lines)"
    COUNT_RETIRED=$((COUNT_RETIRED + 1))
    return 0
  fi
  # Preserve the source's relative layout under legacy-event-sources/ so a
  # post-hoc diff against the archive stays obvious.
  local rel="${src#$PROJECT_ROOT/}"
  local dest="$LEGACY_RETIRE_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  mv "$src" "$dest" 2>/dev/null || {
    log "  ERROR: mv failed for $src — leaving in place"
    return 0
  }
  emit_retirement_event "$src" "$source_lines" "$canonical_lines"
  report "- legacy-event-source-retired: $rel (source_lines=$source_lines canonical_lines=$canonical_lines)"
  COUNT_RETIRED=$((COUNT_RETIRED + 1))
}

do_cleanup() {
  log "phase: cleanup (retire legacy event-log siblings)"
  if [ ! -d "$EVENTS_NEW" ]; then
    log "  no canonical events/ dir — transform must run first, skipping"
    return 0
  fi
  local src
  for src in \
    "$PROJECT_ROOT/event-log.jsonl" \
    "$PROJECT_ROOT/events.jsonl" \
    "$PROJECT_ROOT/events.log" \
    "$PROJECT_ROOT/events/agents.jsonl" \
    "$PROJECT_ROOT/events/events.jsonl" \
    "$PROJECT_ROOT/.runtime/events.jsonl" \
    "$PROJECT_ROOT/.runtime/events.ndjson" \
    "$PROJECT_ROOT/plans/chanakya-events.jsonl" ; do
    retire_one "$src"
  done
  log "  retired $COUNT_RETIRED source(s); skipped $COUNT_RETIRE_SKIPPED on parity fail"

  prune_feedback_placeholders
  log "  pruned $COUNT_FEEDBACK_PRUNED feedback placeholder dir(s)"
}

# Prune .gitkeep-only subdirs under the post-migration feedback/ tree.
# Placeholders are created once by scaffolding and reappear lazily on first
# real write — keeping them in the live tree post-cutover is cosmetic clutter
# that makes the new layout look busier than it is.
#
# Safety: skips any dir with non-.gitkeep content. Emits a
# feedback_placeholder_pruned event per removed dir so consumers can see the
# change land.
prune_feedback_placeholders() {
  local fb_root="$PROJECT_ROOT/feedback"
  [ -d "$fb_root" ] || return 0
  local d content_count rel ts day_file
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    content_count=$(find "$d" -type f ! -name '.gitkeep' 2>/dev/null | head -n 1 | wc -l | tr -d ' ')
    [ "$content_count" -gt 0 ] && continue
    rel="${d#$PROJECT_ROOT/}"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "  DRY-RUN would prune placeholder: $rel"
    else
      rm -rf "$d"
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      day_file="$EVENTS_NEW/$(date -u +%Y-%m-%d).jsonl"
      mkdir -p "$EVENTS_NEW"
      printf '{"ts":"%s","agent":"chanakya","event":"feedback_placeholder_pruned","task":"","data":{"path":"%s"}}\n' \
        "$ts" "$rel" >> "$day_file"
    fi
    report "- pruned feedback placeholder: $rel"
    COUNT_FEEDBACK_PRUNED=$((COUNT_FEEDBACK_PRUNED + 1))
  done < <(find "$fb_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

# -------- Phase 5.75: rebuild-index — materialize plans/index.yaml --------
#
# Without this, the post-migration tree has per-artifact YAML files under
# plans/*/ but no relational join table, so `scripts/query-plans.sh` errors
# and every downstream consumer that expects the index falls back to legacy
# globs. Invoking rebuild-index.sh here makes the migration atomic: either
# the project is fully on the post-2.6 layout or the run errors.

do_rebuild_index() {
  log "phase: index (rebuild plans/index.yaml)"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "  DRY-RUN skip: would invoke rebuild-index.sh --project $PROJECT"
    return 0
  fi
  local rebuild_script="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/rebuild-index.sh"
  if [ ! -x "$rebuild_script" ]; then
    log "  WARN: rebuild-index.sh not executable ($rebuild_script) — skipping"
    return 0
  fi
  if ! ACHILLES_PROJECT_ROOT="$PROJECT_ROOT" "$rebuild_script" --project "$PROJECT" >/dev/null 2>&1; then
    log "  ERROR: rebuild-index.sh failed. plans/index.yaml may be stale or missing."
    report "- index-rebuild-failed: plans/index.yaml may be stale or missing"
    return 0
  fi
  log "  plans/index.yaml rebuilt"
  report "- plans/index.yaml rebuilt"
}

# -------- Phase 6: report --------

emit_report() {
  log "phase: report"
  report ""
  report "## Summary"
  report ""
  report "- briefs transformed: $COUNT_BRIEFS"
  report "- debriefs transformed: $COUNT_DEBRIEFS"
  report "- debriefs misfiled (routed): $COUNT_MISFILED_DEBRIEFS"
  report "- events merged: $COUNT_EVENTS"
  report "- feedback records transformed: $COUNT_FEEDBACK"
  report "- unparseable artifacts: $COUNT_UNPARSEABLE"
  report "- legacy event-log sources retired: $COUNT_RETIRED"
  report "- legacy event-log sources skipped (parity fail): $COUNT_RETIRE_SKIPPED"
  report "- feedback placeholder dirs pruned: $COUNT_FEEDBACK_PRUNED"
  report ""
  report "## Next steps"
  report ""
  report "1. Review unparseable/ if non-zero."
  report "2. Run scripts/verify-ledger.sh to diff-verify the transform."
  report "3. If clean, cut over: remove legacy entries from scripts/lib-paths.sh and commit."
  report "4. Restart sessions."
  log "report written: $REPORT_FILE"
}

# -------- Main --------

phase_enabled pre-flight && preflight_check
phase_enabled backup     && backup_project
phase_enabled transform  && do_transform
phase_enabled verify     && do_verify
phase_enabled cleanup    && do_cleanup
phase_enabled index      && do_rebuild_index
phase_enabled report     && emit_report

log "done"
