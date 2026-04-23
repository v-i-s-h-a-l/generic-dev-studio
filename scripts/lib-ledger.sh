#!/usr/bin/env bash
# lib-ledger.sh — sourced library for ledger mutations (Phase 2.6.5 commit 3).
#
# Every extraction script that mutates a plans/<kind>/ artifact routes through
# these helpers. The library is load-bearing for the dual-write transition
# (see _shared/patterns/dual-write-transition.md): one call site, YAML + legacy
# written atomically from the caller's perspective, partial-failure surfaced
# via `dual_write_partial` events + exit 3.
#
# Exposes:
#   Utilities
#     mint_uuidv7                             time-ordered RFC-9562 UUIDv7
#     iso_ts_now                              RFC3339 UTC timestamp
#     yaml_quote <string>                     double-quoted YAML scalar (escaped)
#
#   Idempotency
#     idem_key <agent> <kind> <subject> <content>   per contracts/idempotency.md
#
#   Event emission
#     emit_event_keyed <agent> <mode> <event> <task> <data-json> \
#                      [--instance-id <id>] [--idem-key <k>]
#                                             appends event envelope per
#                                             contracts/event-emission.md
#
#   State transitions (dual-write YAML + legacy)
#     transition_task_state    <uuid> <to> <actor> <reason>
#     transition_brief_state   <uuid> <to> <actor> <reason>
#     transition_release_state <uuid> <to> <actor> <reason>
#     transition_review_state  <uuid> <to> <actor> <reason>
#     transition_round_state   <uuid> <to> <actor> <reason>
#
#   Link mutations (task-side; no events — callers emit)
#     set_task_link    <uuid> <brief|debrief|release> <target-uuid>
#     append_task_link <uuid> <reviews|feedback>      <target-uuid>
#
#   Artifact writers (net-new YAML + legacy dual-write + event)
#     write_task_artifact     <uuid> <state> <title> [k=v...]
#     write_brief_artifact    <brief-uuid> <task-uuid> <type> <size> [k=v...]
#     write_debrief_artifact  <uuid> <task-uuid|null> <brief-uuid|null> <mode> <state> [k=v...]
#     write_review_artifact   <uuid> <subject-kind> <subject-uuid> <verdict> <findings-json>
#     write_round_artifact    <uuid> <round-number> <scope> <tasks-csv> <body>
#     write_release_artifact  <uuid> <channel> <version> <build> <tag> <tasks-csv>
#
#   Legacy counterpart helpers (markdown surgery)
#     legacy_master_plan_set_status    <legacy-id> <status> [commits] [merge]
#     legacy_master_plan_append_row    <legacy-id> <title> <priority> <type> <source> <status>
#     legacy_master_plan_archive_task  <legacy-id>
#     legacy_inbox_move_to_processed   <debrief-filename>
#     legacy_inbox_write_debrief       <legacy-id> <path> <body>
#     legacy_brief_write_markdown      <legacy-id> <slug> <body>
#     legacy_review_write_markdown     <legacy-id> <body>
#     legacy_round_write_markdown      <round-number> <body>
#     legacy_release_log_append        <build> <version> <type> <date> <tag> <head> <tasks-csv>
#
#   Batching
#     flush_index                             rebuild plans/index.yaml now
#
# Env controls (all optional):
#   DUAL_WRITE_MODE   `both` (default) | `yaml-only`           Commit H flips default
#   DRY_RUN           `1` to log + buffer without filesystem writes
#   WITHHOLD_INDEX    `1` to skip rebuild-index per mutation (callers batch)
#
# Exit codes:
#   0   success
#   2   validation error (unknown kind, missing file, malformed input)
#   3   dual-write partial failure (YAML ok, legacy failed) — event emitted
#   9   not-implemented legacy helper (see stubs below)
#
# No `set -e` — sourced into scripts that may or may not want strict mode.

# Script dir resolves so relative sources (rebuild-index.sh) work even when
# caller is invoked from another cwd.
LEDGER_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# shellcheck source=lib-paths.sh
. "$LEDGER_LIB_DIR/lib-paths.sh" 2>/dev/null || true

# DRY-RUN buffer — callers can inspect emitted events after the run.
LEDGER_DRY_RUN_EVENTS=""

# ---------- Utilities ----------

# UUIDv7 per RFC 9562 §5.7 — 48-bit Unix-ms prefix, version nibble `7`, variant
# bits `10` in the clock-seq high nibble. Random body via /dev/urandom.
# macOS-portable: prefers perl for Time::HiRes; falls back to seconds-resolution
# if perl is unavailable (ordering degrades, not correctness).
mint_uuidv7() {
  local ms_hex rand_hex a b c d e
  if command -v perl >/dev/null 2>&1; then
    ms_hex=$(perl -MTime::HiRes -e 'printf "%012x", int(Time::HiRes::time()*1000)')
  else
    ms_hex=$(printf '%012x' $(( $(date -u +%s) * 1000 )))
  fi
  # 20 bytes of randomness → 40 hex chars; we need 18 hex after the ms prefix.
  rand_hex=$(od -An -N20 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -z "$rand_hex" ] && rand_hex=$(printf '%s' "$$$(date +%N 2>/dev/null)$RANDOM$RANDOM$RANDOM$RANDOM$RANDOM$RANDOM" | od -An -tx1 | tr -d ' \n')
  a="${ms_hex:0:8}"
  b="${ms_hex:8:4}"
  # Version nibble `7` + 12 bits of randomness.
  c="7${rand_hex:0:3}"
  # Variant bits `10xx` → high nibble is 8/9/a/b; force `a` for determinism.
  d="a${rand_hex:3:3}"
  e="${rand_hex:6:12}"
  printf '%s-%s-%s-%s-%s\n' "$a" "$b" "$c" "$d" "$e"
}

iso_ts_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

yaml_quote() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# sha1 of stdin — first 8 hex chars. macOS `shasum`, GNU `sha1sum`, both OK.
_sha1_first8() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 1 | awk '{print substr($1, 1, 8)}'
  else
    sha1sum | awk '{print substr($1, 1, 8)}'
  fi
}

# ---------- Idempotency ----------

idem_key() {
  local agent="${1:?idem_key <agent> <kind> <subject> <content>}"
  local kind="${2:?}" subject="${3:?}" content="${4:-}"
  local hash
  hash=$(printf '%s' "$content" | _sha1_first8)
  printf '%s:%s:%s:%s\n' "$agent" "$kind" "$subject" "$hash"
}

# ---------- Event emission ----------

# Escape a JSON-ish string for safe embedding in the envelope. Sufficient for
# producer/idempotency_key scalars — not a general JSON serializer.
_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

emit_event_keyed() {
  local agent="${1:?emit_event_keyed <agent> <mode> <event> <task> <data-json>}"
  local mode="${2:?}" event="${3:?}" task="${4:-}" data="${5:-{\}}"
  shift 5
  local instance_id="" idem=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance-id) instance_id="${2:-}"; shift 2 ;;
      --idem-key)    idem="${2:-}";        shift 2 ;;
      *) printf 'emit_event_keyed: unknown flag %s\n' "$1" >&2; return 2 ;;
    esac
  done

  local ts line
  ts=$(iso_ts_now)
  # Build envelope. `producer` is always present; `idempotency_key` only if set
  # (session-lifecycle events per contracts/event-emission.md §2 omit it).
  if [ -n "$idem" ]; then
    line=$(printf '{"ts":"%s","agent":"%s","event":"%s","task":"%s","data":%s,"producer":{"agent":"%s","mode":"%s","instance_id":"%s"},"idempotency_key":"%s"}' \
      "$ts" \
      "$(_json_escape "$agent")" \
      "$(_json_escape "$event")" \
      "$(_json_escape "$task")" \
      "$data" \
      "$(_json_escape "$agent")" \
      "$(_json_escape "$mode")" \
      "$(_json_escape "$instance_id")" \
      "$(_json_escape "$idem")")
  else
    line=$(printf '{"ts":"%s","agent":"%s","event":"%s","task":"%s","data":%s,"producer":{"agent":"%s","mode":"%s","instance_id":"%s"}}' \
      "$ts" \
      "$(_json_escape "$agent")" \
      "$(_json_escape "$event")" \
      "$(_json_escape "$task")" \
      "$data" \
      "$(_json_escape "$agent")" \
      "$(_json_escape "$mode")" \
      "$(_json_escape "$instance_id")")
  fi

  # O_APPEND atomicity cap — PIPE_BUF on macOS/Linux.
  local bytes
  bytes=$(printf '%s' "$line" | wc -c | tr -d ' ')
  if [ "$bytes" -gt 4096 ]; then
    printf 'emit_event_keyed: payload %s bytes > 4096 cap (contracts/events.md §atomicity)\n' "$bytes" >&2
    return 3
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN event %s agent=%s mode=%s task=%s\n' "$event" "$agent" "$mode" "$task" >&2
    LEDGER_DRY_RUN_EVENTS="${LEDGER_DRY_RUN_EVENTS}${line}"$'\n'
    printf '%s\n' "$line"
    return 0
  fi

  local log
  log=$(resolve_event_log) || return 2
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  printf '%s\n' "$line" >> "$log"
  printf '%s\n' "$line"
}

# ---------- Dual-write gating ----------

# Single consultation point so Commit H flips the default by editing only
# this function + the env-var documentation.
_lw_dual_write_enabled() {
  case "${DUAL_WRITE_MODE:-both}" in
    both) return 0 ;;
    yaml-only) return 1 ;;
    *) printf '_lw_dual_write_enabled: unknown DUAL_WRITE_MODE=%s\n' "$DUAL_WRITE_MODE" >&2; return 1 ;;
  esac
}

# Emit dual_write_partial + return 3. Shared across every dual-writer.
_emit_dual_write_partial() {
  local agent="${1:?}" mode="${2:?}" subject_kind="${3:?}" subject_uuid="${4:?}" legacy_path="${5:?}" reason="${6:?}"
  local data
  data=$(printf '{"subject_kind":"%s","subject_uuid":"%s","legacy_path":"%s","reason":"%s"}' \
    "$(_json_escape "$subject_kind")" \
    "$(_json_escape "$subject_uuid")" \
    "$(_json_escape "$legacy_path")" \
    "$(_json_escape "$reason")")
  emit_event_keyed "$agent" "$mode" dual_write_partial "$subject_uuid" "$data" >/dev/null || true
  return 3
}

# ---------- Index batching ----------

# One rebuild per mutation unless the caller set WITHHOLD_INDEX. Callers with
# N mutations batch-set WITHHOLD_INDEX=1, call helpers, then flush_index once.
_maybe_rebuild_index() {
  [ "${WITHHOLD_INDEX:-0}" = "1" ] && return 0
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  local rebuild="$LEDGER_LIB_DIR/rebuild-index.sh"
  [ -x "$rebuild" ] || return 0
  local project
  project=$(resolve_project 2>/dev/null) || return 0
  "$rebuild" --project "$project" >/dev/null 2>&1 || true
}

flush_index() {
  local saved="${WITHHOLD_INDEX:-0}"
  WITHHOLD_INDEX=0
  _maybe_rebuild_index
  WITHHOLD_INDEX="$saved"
}

# ---------- Artifact-path resolvers ----------

# Resolve plans/<kind>/<uuid>.yaml for the current project. Callers that have
# already resolved the project can set LEDGER_PROJECT_ROOT to skip the
# resolve_project round-trip.
_artifact_path() {
  local kind="${1:?}" uuid="${2:?}"
  local root
  if [ -n "${LEDGER_PROJECT_ROOT:-}" ]; then
    root="$LEDGER_PROJECT_ROOT"
  else
    local project
    project=$(resolve_project) || return 2
    root=$(resolve_project_root_for "$project") || return 2
  fi
  printf '%s/plans/%s/%s.yaml\n' "$root" "$kind" "$uuid"
}

# ---------- DRY-RUN helper ----------

# Emit the canonical DRY-RUN write line per patterns/dry-run.md.
_dry_write_log() {
  local path="$1" payload="$2" idem="$3"
  local bytes
  bytes=$(printf '%s' "$payload" | wc -c | tr -d ' ')
  printf 'DRY-RUN write path=%s bytes=%s idempotency_key=%s\n' "$path" "$bytes" "$idem" >&2
}

# Write YAML atomically via tmp + mv. Invariant: either the full file lands
# or nothing does — protects readers mid-write.
_atomic_write() {
  local path="$1" payload="$2"
  local dir tmp
  dir=$(dirname "$path")
  mkdir -p "$dir" 2>/dev/null || return 2
  tmp="$path.tmp.$$"
  printf '%s' "$payload" > "$tmp" || { rm -f "$tmp"; return 2; }
  mv "$tmp" "$path" || { rm -f "$tmp"; return 2; }
}

# ---------- State transitions ----------
#
# Invariant order: read YAML, mutate, atomic-write YAML, call legacy helper,
# emit event. YAML-first matches dual-write-transition.md rule 2 (crash after
# step 1 leaves the system biased toward the post-transition shape).

_transition_artifact() {
  local kind="${1:?}" uuid="${2:?}" to_state="${3:?}" actor="${4:?}" reason="${5:-}"
  local f
  f=$(_artifact_path "$kind" "$uuid") || return 2
  if [ ! -f "$f" ]; then
    printf '_transition_artifact: no artifact at %s\n' "$f" >&2
    return 2
  fi

  local from_state
  from_state=$(yq -r '.state // "null"' "$f" 2>/dev/null || echo null)
  if [ "$from_state" = "$to_state" ]; then
    return 0
  fi

  local ts event_id
  ts=$(iso_ts_now)
  event_id=$(mint_uuidv7)

  # Idempotency key folds in from+to+ts so a rerun on the same transition
  # recomputes to the same key (retry safety) but a second distinct transition
  # later gets a new key.
  local legacy_task_id
  legacy_task_id=$(yq -r '.legacy_task_id // ""' "$f" 2>/dev/null || echo "")
  local subject="$uuid"
  [ -n "$legacy_task_id" ] && subject="$legacy_task_id"
  # Singular kind in the key subject-prefix so retries against the same task
  # collide regardless of caller-naming (`tasks` vs `task`).
  local kind_singular
  case "$kind" in
    tasks) kind_singular=task ;;
    briefs) kind_singular=brief ;;
    releases) kind_singular=release ;;
    reviews) kind_singular=review ;;
    rounds) kind_singular=round ;;
    *) kind_singular="$kind" ;;
  esac
  local idem
  idem=$(idem_key "$actor" "$kind_singular" "$subject" "$from_state>$to_state")

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "state=$to_state" "$idem"
  else
    local reason_safe="${reason//\"/\\\"}"
    yq -i \
      ".state = \"$to_state\" | .updated_at = \"$ts\" | .history += [{\"from\": \"$from_state\", \"to\": \"$to_state\", \"actor\": \"$actor\", \"at\": \"$ts\", \"event_id\": \"$event_id\", \"reason\": \"$reason_safe\"}]" \
      "$f" 2>/dev/null || return 2
  fi

  # Dual-write. The legacy counterpart shape depends on kind.
  if _lw_dual_write_enabled; then
    case "$kind" in
      tasks)
        if [ -n "$legacy_task_id" ]; then
          local legacy_status
          legacy_status=$(_state_to_legacy_status "$to_state")
          if ! legacy_master_plan_set_status "$legacy_task_id" "$legacy_status"; then
            local project legacy_path
            project=$(resolve_project 2>/dev/null || echo unknown)
            legacy_path="$(resolve_plans_dir_for "$project")/chanakya-master.md"
            _emit_dual_write_partial "$actor" "$kind" task "$uuid" "$legacy_path" "legacy_master_plan_set_status_failed" || return 3
          fi
        fi
        ;;
      releases|rounds|reviews|briefs)
        # These state-only transitions touch the legacy master-plan or markdown
        # only on status-sensitive transitions. The Phase 2.6.5 spine keeps the
        # state flip + event emission; the corresponding legacy markdown is
        # regenerated (not incrementally mutated) by its dedicated writer.
        :
        ;;
    esac
  fi

  # Event emission — domain event names match _shared/contracts/events.md.
  # `producer.mode` uses the singular kind (`task`, `brief`, …) to align with
  # idempotency.md's stable-subject convention.
  local event_name mode_name
  case "$kind" in
    tasks)    event_name=task_state_changed;    mode_name=task ;;
    briefs)   event_name=brief_state_changed;   mode_name=brief ;;
    releases) event_name=release_state_changed; mode_name=release ;;
    reviews)  event_name=review_state_changed;  mode_name=review ;;
    rounds)   event_name=round_state_changed;   mode_name=round ;;
    *) printf '_transition_artifact: unknown kind %s\n' "$kind" >&2; return 2 ;;
  esac
  local data
  data=$(printf '{"from":"%s","to":"%s","actor":"%s","event_id":"%s"}' \
    "$(_json_escape "$from_state")" "$(_json_escape "$to_state")" "$(_json_escape "$actor")" "$event_id")
  emit_event_keyed "$actor" "$mode_name" "$event_name" "$uuid" "$data" --idem-key "$idem" >/dev/null || return $?

  _maybe_rebuild_index
}

transition_task_state()    { _transition_artifact tasks    "$1" "$2" "$3" "${4:-}"; }
transition_brief_state()   { _transition_artifact briefs   "$1" "$2" "$3" "${4:-}"; }
transition_release_state() { _transition_artifact releases "$1" "$2" "$3" "${4:-}"; }
transition_review_state()  { _transition_artifact reviews  "$1" "$2" "$3" "${4:-}"; }
transition_round_state()   { _transition_artifact rounds   "$1" "$2" "$3" "${4:-}"; }

# Post-2.6 state → legacy master-plan Status column. Inverse of the
# transform_tasks mapping in migrate-ledger.sh.
_state_to_legacy_status() {
  case "$1" in
    proposed)           printf 'pending' ;;
    briefed)            printf 'briefed' ;;
    dispatched)         printf 'briefed' ;;
    in-progress)        printf 'in-progress' ;;
    self-reviewed)      printf 'in-progress' ;;
    argus-reviewed)     printf 'in-progress' ;;
    merged)             printf 'done' ;;
    user-verifying)     printf 'done' ;;
    verified)           printf 'verified' ;;
    rejected)           printf 'needs-review' ;;
    blocked)            printf 'blocked' ;;
    cancelled)          printf 'cancelled' ;;
    archived)           printf 'done' ;;
    *)                  printf '%s' "$1" ;;
  esac
}

# ---------- Link mutations ----------

set_task_link() {
  local uuid="${1:?set_task_link <task-uuid> <kind> <target-uuid>}"
  local link_kind="${2:?}" target="${3:?}"
  case "$link_kind" in
    brief|debrief|release) ;;
    *) printf 'set_task_link: unknown link kind %s (want brief|debrief|release)\n' "$link_kind" >&2; return 2 ;;
  esac
  local f
  f=$(_artifact_path tasks "$uuid") || return 2
  [ -f "$f" ] || { printf 'set_task_link: no task at %s\n' "$f" >&2; return 2; }

  local current
  current=$(yq -r ".links.$link_kind // \"\"" "$f" 2>/dev/null || echo "")
  [ "$current" = "$target" ] && return 0

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "links.$link_kind=$target" "$(idem_key link set "$uuid:$link_kind" "$target")"
    return 0
  fi

  local ts
  ts=$(iso_ts_now)
  yq -i ".links.$link_kind = \"$target\" | .updated_at = \"$ts\"" "$f" 2>/dev/null || return 2
  _maybe_rebuild_index
}

append_task_link() {
  local uuid="${1:?append_task_link <task-uuid> <kind> <target-uuid>}"
  local link_kind="${2:?}" target="${3:?}"
  case "$link_kind" in
    reviews|feedback) ;;
    *) printf 'append_task_link: unknown link kind %s (want reviews|feedback)\n' "$link_kind" >&2; return 2 ;;
  esac
  local f
  f=$(_artifact_path tasks "$uuid") || return 2
  [ -f "$f" ] || { printf 'append_task_link: no task at %s\n' "$f" >&2; return 2; }

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "links.$link_kind+=$target" "$(idem_key link append "$uuid:$link_kind" "$target")"
    return 0
  fi

  local ts
  ts=$(iso_ts_now)
  yq -i \
    ".links.$link_kind = ((.links.$link_kind // []) + [\"$target\"] | unique) | .updated_at = \"$ts\"" \
    "$f" 2>/dev/null || return 2
  _maybe_rebuild_index
}

# ---------- YAML fragment helpers ----------

# CSV of identifiers → inline YAML array `[a, b, c]`. Empty CSV → `[]`.
# Used by round + release writers to render the `tasks:` field consistently.
_csv_to_yaml_array() {
  local csv="${1:-}"
  [ -z "$csv" ] && { printf '[]'; return 0; }
  local IFS=',' first=1 tid rendered=""
  for tid in $csv; do
    [ -z "$tid" ] && continue
    if [ "$first" -eq 1 ]; then rendered="$tid"; first=0; else rendered="$rendered, $tid"; fi
  done
  printf '[%s]' "$rendered"
}

# Appends `key: value` lines for each k=v pair (value is YAML-quoted unless it
# already starts with `[`, `{`, or is a number / null / true / false). Used by
# writers to carry optional fields (`description`, `notes`, …) without
# hard-coding every schema extension.
_append_kv_lines() {
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    [ -z "$key" ] && continue
    case "$value" in
      \[*|\{*|true|false|null)        printf '%s: %s\n' "$key" "$value" ;;
      ''|*[!0-9.-]*)                  printf '%s: %s\n' "$key" "$(yaml_quote "$value")" ;;
      *)                              printf '%s: %s\n' "$key" "$value" ;;
    esac
  done
}

# ---------- Artifact writers ----------
#
# Same shape as _transition_artifact — YAML-first, legacy second, event last.
# Partial failure (YAML ok, legacy fail) emits dual_write_partial + exits 3.

write_task_artifact() {
  local uuid="${1:?write_task_artifact <uuid> <state> <title> [k=v...]}"
  local state="${2:?}" title="${3:?}"
  shift 3

  local f ts
  f=$(_artifact_path tasks "$uuid") || return 2
  ts=$(iso_ts_now)
  local event_id
  event_id=$(mint_uuidv7)
  local idem
  idem=$(idem_key chanakya task "$uuid" "state=$state;title=$title")

  local payload
  payload=$({
    printf 'schema_version: {name: task, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}\n'
    printf 'id: %s\n' "$uuid"
    printf 'title: %s\n' "$(yaml_quote "$title")"
    printf 'state: %s\n' "$state"
    printf 'size: m\n'
    printf 'created_at: %s\n' "$ts"
    printf 'updated_at: %s\n' "$ts"
    printf 'links:\n  brief: null\n  debrief: null\n  reviews: []\n  release: null\n  feedback: []\n'
    printf 'history:\n'
    printf '  - {from: null, to: %s, actor: chanakya, at: %s, event_id: %s, reason: ""}\n' \
      "$state" "$ts" "$event_id"
    _append_kv_lines "$@"
  })

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "$payload" "$idem"
  else
    _atomic_write "$f" "$payload" || return 2
  fi

  # Legacy dual-write — append a master-plan row. Legacy task id comes from
  # k=v pairs when present; otherwise we skip (post-cutover tasks have no
  # legacy rowID).
  if _lw_dual_write_enabled; then
    local legacy_task_id=""
    local pair
    for pair in "$@"; do
      case "$pair" in
        legacy_task_id=*) legacy_task_id="${pair#legacy_task_id=}" ;;
      esac
    done
    if [ -n "$legacy_task_id" ]; then
      local legacy_status
      legacy_status=$(_state_to_legacy_status "$state")
      if ! legacy_master_plan_append_row "$legacy_task_id" "$title" "P2" "—" "—" "$legacy_status"; then
        local project legacy_path
        project=$(resolve_project 2>/dev/null || echo unknown)
        legacy_path="$(resolve_plans_dir_for "$project")/chanakya-master.md"
        _emit_dual_write_partial chanakya task task "$uuid" "$legacy_path" "legacy_master_plan_append_row_failed" || return 3
      fi
    fi
  fi

  local data
  data=$(printf '{"from":null,"to":"%s","actor":"chanakya","event_id":"%s"}' \
    "$(_json_escape "$state")" "$event_id")
  emit_event_keyed chanakya task task_state_changed "$uuid" "$data" --idem-key "$idem" >/dev/null || return $?
  _maybe_rebuild_index
}

write_brief_artifact() {
  local uuid="${1:?write_brief_artifact <brief-uuid> <task-uuid> <type> <size> [k=v...]}"
  local task_uuid="${2:?}" type="${3:?}" size="${4:?}"
  shift 4

  local f ts
  f=$(_artifact_path briefs "$uuid") || return 2
  ts=$(iso_ts_now)
  local idem
  idem=$(idem_key chanakya brief "$uuid" "task=$task_uuid;type=$type;size=$size")

  local payload
  payload=$({
    printf 'schema_version: {name: brief, version: 3.1.0, min_reader: 3.0.0, deprecated_at: null}\n'
    printf 'id: %s\n' "$uuid"
    printf 'task_id: %s\n' "$task_uuid"
    printf 'type: %s\n' "$type"
    printf 'size: %s\n' "$size"
    printf 'state: draft\n'
    printf 'created_at: %s\n' "$ts"
    printf 'updated_at: %s\n' "$ts"
    printf 'figma: null\n'
    printf 'reads: []\n'
    printf 'writes: []\n'
    printf 'acceptance: []\n'
    printf 'testability: []\n'
    printf 'rework_of: null\n'
    _append_kv_lines "$@"
  })

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "$payload" "$idem"
  else
    _atomic_write "$f" "$payload" || return 2
  fi

  if _lw_dual_write_enabled; then
    local legacy_task_id="" slug="$type" body=""
    local pair
    for pair in "$@"; do
      case "$pair" in
        legacy_task_id=*) legacy_task_id="${pair#legacy_task_id=}" ;;
        slug=*)           slug="${pair#slug=}" ;;
        body=*)           body="${pair#body=}" ;;
      esac
    done
    if [ -n "$legacy_task_id" ]; then
      if ! legacy_brief_write_markdown "$legacy_task_id" "$slug" "$body"; then
        local project legacy_path
        project=$(resolve_project 2>/dev/null || echo unknown)
        legacy_path="$(resolve_plans_dir_for "$project")/chanakya-tasks/${legacy_task_id}-${slug}.md"
        _emit_dual_write_partial chanakya brief brief "$uuid" "$legacy_path" "legacy_brief_write_markdown_failed" || return 3
      fi
    fi
  fi

  local data
  data=$(printf '{"from":null,"to":"draft","task_id":"%s"}' "$(_json_escape "$task_uuid")")
  emit_event_keyed chanakya brief brief_state_changed "$uuid" "$data" --idem-key "$idem" >/dev/null || return $?
  _maybe_rebuild_index
}

_validate_report_state() {
  # Enforce the worker-report enum per _shared/contracts/worker-report.md.
  # Empty/unset is allowed (back-compat; readers infer from other fields).
  local v="${1:-}"
  [ -z "$v" ] && return 0
  case "$v" in
    done|done_with_concerns|blocked|needs_context) return 0 ;;
    *) printf 'lib-ledger: invalid report_state=%s (want: done|done_with_concerns|blocked|needs_context)\n' "$v" >&2
       return 1 ;;
  esac
}

write_debrief_artifact() {
  local uuid="${1:?write_debrief_artifact <uuid> <task-uuid|null> <brief-uuid|null> <mode> <state> [k=v...]}"
  local task_uuid="${2:-null}" brief_uuid="${3:-null}" mode="${4:?}" state="${5:?}"
  shift 5

  # Worker-report contract: scan args for report_state, validate if present.
  local _pair _report_state=""
  for _pair in "$@"; do
    case "$_pair" in
      report_state=*) _report_state="${_pair#report_state=}" ;;
    esac
  done
  _validate_report_state "$_report_state" || return 2

  local f ts
  f=$(_artifact_path debriefs "$uuid") || return 2
  ts=$(iso_ts_now)
  local idem
  idem=$(idem_key achilles debrief "$uuid" "task=$task_uuid;brief=$brief_uuid;mode=$mode")

  local task_line brief_line
  if [ "$task_uuid" = "null" ] || [ -z "$task_uuid" ]; then
    task_line="task_id: null"
  else
    task_line="task_id: $task_uuid"
  fi
  if [ "$brief_uuid" = "null" ] || [ -z "$brief_uuid" ]; then
    brief_line="brief_id: null"
  else
    brief_line="brief_id: $brief_uuid"
  fi

  local payload
  payload=$({
    printf 'schema_version: {name: debrief, version: 2.0.2, min_reader: 2.0.0, deprecated_at: null}\n'
    printf 'id: %s\n' "$uuid"
    printf '%s\n' "$task_line"
    printf '%s\n' "$brief_line"
    printf 'mode: %s\n' "$mode"
    printf 'state: %s\n' "$state"
    printf 'completed_at: %s\n' "$ts"
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
    _append_kv_lines "$@"
  })

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "$payload" "$idem"
  else
    _atomic_write "$f" "$payload" || return 2
  fi

  if _lw_dual_write_enabled; then
    local legacy_task_id="" body=""
    local pair
    for pair in "$@"; do
      case "$pair" in
        legacy_task_id=*) legacy_task_id="${pair#legacy_task_id=}" ;;
        body=*)           body="${pair#body=}" ;;
      esac
    done
    if [ -n "$legacy_task_id" ]; then
      local project legacy_path
      project=$(resolve_project 2>/dev/null || echo unknown)
      legacy_path="$(resolve_plans_dir_for "$project")/chanakya-inbox/${legacy_task_id}-debrief.md"
      if ! legacy_inbox_write_debrief "$legacy_task_id" "$legacy_path" "$body"; then
        _emit_dual_write_partial achilles debrief debrief "$uuid" "$legacy_path" "legacy_inbox_write_debrief_failed" || return 3
      fi
    fi
  fi

  local data
  if [ -n "$_report_state" ]; then
    data=$(printf '{"mode":"%s","state":"%s","report_state":"%s"}' \
      "$(_json_escape "$mode")" "$(_json_escape "$state")" "$(_json_escape "$_report_state")")
  else
    data=$(printf '{"mode":"%s","state":"%s"}' "$(_json_escape "$mode")" "$(_json_escape "$state")")
  fi
  emit_event_keyed achilles debrief debrief_emitted "$uuid" "$data" --idem-key "$idem" >/dev/null || return $?
  _maybe_rebuild_index
}

write_review_artifact() {
  local uuid="${1:?write_review_artifact <uuid> <subject-kind> <subject-uuid> <verdict> <findings-json>}"
  local subject_kind="${2:?}" subject_uuid="${3:?}" verdict="${4:?}" findings_json="${5:-[]}"

  local f ts
  f=$(_artifact_path reviews "$uuid") || return 2
  ts=$(iso_ts_now)
  local idem
  idem=$(idem_key argus review "$subject_uuid" "verdict=$verdict")

  local payload
  payload=$({
    printf 'schema_version: {name: review, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}\n'
    printf 'id: %s\n' "$uuid"
    printf 'subject: {kind: %s, id: %s}\n' "$subject_kind" "$subject_uuid"
    printf 'reviewer: argus\n'
    printf 'state: %s\n' "$verdict"
    printf 'requested_at: %s\n' "$ts"
    printf 'completed_at: %s\n' "$ts"
    printf 'verdict: %s\n' "$verdict"
    printf 'findings: %s\n' "$findings_json"
    printf 'checks_run: []\n'
    printf 'scope: {diff_size: 0, file_count: 0, caps_triggered: []}\n'
    printf 'notes: null\n'
  })

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "$payload" "$idem"
  else
    _atomic_write "$f" "$payload" || return 2
  fi

  if _lw_dual_write_enabled; then
    # Legacy reviews are free-form markdown under project memory. The helper is
    # stubbed exit-9 in this commit; the dual-write tries but does not fail the
    # caller if the stub reports "not implemented" — reviews are read-mostly
    # legacy, and pre-cutover dual-write wasn't wired for them (unlike briefs
    # + debriefs which are actively produced). This is the minimum-risk
    # default; raise the bar by implementing legacy_review_write_markdown.
    legacy_review_write_markdown "$subject_uuid" "" >/dev/null 2>&1 || true
  fi

  local data
  data=$(printf '{"subject_kind":"%s","subject_uuid":"%s","verdict":"%s"}' \
    "$(_json_escape "$subject_kind")" "$(_json_escape "$subject_uuid")" "$(_json_escape "$verdict")")
  local event_name
  case "$verdict" in
    approved) event_name=review_approved ;;
    flagged)  event_name=review_flagged ;;
    blocked)  event_name=review_blocked ;;
    *)        event_name=review_state_changed ;;
  esac
  emit_event_keyed argus review "$event_name" "$subject_uuid" "$data" --idem-key "$idem" >/dev/null || return $?
  _maybe_rebuild_index
}

write_round_artifact() {
  local uuid="${1:?write_round_artifact <uuid> <round-number> <scope> <tasks-csv> <body>}"
  local round_num="${2:?}" scope="${3:?}" tasks_csv="${4:-}" body="${5:-}"

  local f ts
  f=$(_artifact_path rounds "$uuid") || return 2
  ts=$(iso_ts_now)
  local idem
  idem=$(idem_key chanakya round "round-$round_num" "scope=$scope;tasks=$tasks_csv")

  local tasks_yaml
  tasks_yaml=$(_csv_to_yaml_array "$tasks_csv")

  local indented_body
  indented_body=$(printf '%s' "$body" | sed 's/^/  /')

  local payload
  payload=$({
    printf 'schema_version: {name: round, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}\n'
    printf 'id: %s\n' "$uuid"
    printf 'round_number: %s\n' "$round_num"
    printf 'state: open\n'
    printf 'scope: %s\n' "$scope"
    printf 'generated_at: %s\n' "$ts"
    printf 'closed_at: null\n'
    printf 'previous_round: null\n'
    printf 'tested_on: null\n'
    printf 'tasks: %s\n' "$tasks_yaml"
    printf 'reviews: []\n'
    printf 'cases: []\n'
    printf 'summary: {cases_total: 0, pass: 0, fail: 0, pending: 0}\n'
    printf 'body: |\n%s\n' "$indented_body"
  })

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "$payload" "$idem"
  else
    _atomic_write "$f" "$payload" || return 2
  fi

  if _lw_dual_write_enabled; then
    if ! legacy_round_write_markdown "$round_num" "$body"; then
      local project legacy_path
      project=$(resolve_project 2>/dev/null || echo unknown)
      legacy_path="$(resolve_plans_dir_for "$project")/user-testing-rounds/user-testing-round${round_num}.md"
      _emit_dual_write_partial chanakya round round "$uuid" "$legacy_path" "legacy_round_write_markdown_failed" || return 3
    fi
  fi

  local data
  data=$(printf '{"from":null,"to":"open","round_number":%s}' "$round_num")
  emit_event_keyed chanakya round round_state_changed "$uuid" "$data" --idem-key "$idem" >/dev/null || return $?
  _maybe_rebuild_index
}

write_release_artifact() {
  local uuid="${1:?write_release_artifact <uuid> <channel> <version> <build> <tag> <tasks-csv>}"
  local channel="${2:?}" version="${3:?}" build_num="${4:?}" tag="${5:?}" tasks_csv="${6:-}"

  local f ts
  f=$(_artifact_path releases "$uuid") || return 2
  ts=$(iso_ts_now)
  local idem
  idem=$(idem_key achilles release "$tag" "version=$version;build=$build_num")

  local tasks_yaml
  tasks_yaml=$(_csv_to_yaml_array "$tasks_csv")

  local payload
  payload=$({
    printf 'schema_version: {name: release, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}\n'
    printf 'id: %s\n' "$uuid"
    printf 'channel: %s\n' "$channel"
    printf 'state: released\n'
    printf 'build_number: %s\n' "$build_num"
    printf 'version: %s\n' "$(yaml_quote "$version")"
    printf 'tag: %s\n' "$(yaml_quote "$tag")"
    printf 'commit_sha: ""\n'
    printf 'submitted_at: %s\n' "$ts"
    printf 'last_state_checked_at: %s\n' "$ts"
    printf 'released_at: %s\n' "$ts"
    printf 'tasks: %s\n' "$tasks_yaml"
    printf 'reviews: []\n'
    printf 'asc_metadata: null\n'
    printf 'slack: null\n'
    printf 'notes: null\n'
  })

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "$payload" "$idem"
  else
    _atomic_write "$f" "$payload" || return 2
  fi

  if _lw_dual_write_enabled; then
    local today
    today=$(date -u +%Y-%m-%d)
    if ! legacy_release_log_append "$build_num" "$version" "$channel" "$today" "$tag" "" "$tasks_csv"; then
      local project legacy_path
      project=$(resolve_project 2>/dev/null || echo unknown)
      legacy_path="$(resolve_plans_dir_for "$project")/chanakya-master.md"
      _emit_dual_write_partial achilles release release "$uuid" "$legacy_path" "legacy_release_log_append_failed" || return 3
    fi
  fi

  local data
  data=$(printf '{"from":null,"to":"released","channel":"%s","tag":"%s"}' \
    "$(_json_escape "$channel")" "$(_json_escape "$tag")")
  emit_event_keyed achilles release release_state_changed "$uuid" "$data" --idem-key "$idem" >/dev/null || return $?
  _maybe_rebuild_index
}

# ---------- Legacy counterpart helpers ----------
#
# Every helper returns nonzero on any detected drift (missing file, missing
# section, unparseable row). Callers handle that by emitting dual_write_partial.
# Helpers that require parsing the master-plan task-section structure reliably
# are stubbed exit-9 — implementing them safely requires tests against real
# turnip-ios fixture data, which lands with commits 5+.

_master_plan_path() {
  local project
  project=$(resolve_project 2>/dev/null) || return 2
  printf '%s\n' "$(resolve_plans_dir_for "$project")/chanakya-master.md"
}

_chanakya_archive_path() {
  local project
  project=$(resolve_project 2>/dev/null) || return 2
  printf '%s\n' "$(resolve_plans_dir_for "$project")/chanakya-archive.md"
}

_chanakya_inbox_path() {
  local project
  project=$(resolve_project 2>/dev/null) || return 2
  printf '%s\n' "$(resolve_plans_dir_for "$project")/chanakya-inbox"
}

legacy_master_plan_set_status() {
  local legacy_id="${1:?legacy_master_plan_set_status <legacy-task-id> <status> [commits] [merge]}"
  local status="${2:?}"
  local master
  master=$(_master_plan_path) || return 2
  [ -f "$master" ] || { printf 'legacy_master_plan_set_status: missing %s\n' "$master" >&2; return 2; }

  local tmp
  tmp="$master.tmp.$$"
  # Update the Status bullet inside the section starting at `### $legacy_id `.
  # Scope the edit: active only between `### T…` heading for this task and
  # the next `### ` / `## ` boundary.
  awk -v id="$legacy_id" -v new="$status" '
    BEGIN { in_section=0; updated=0 }
    /^### / {
      if ($2 == id) { in_section=1 } else { in_section=0 }
      print; next
    }
    /^## / { in_section=0; print; next }
    in_section==1 && /^- \*\*Status:\*\*/ {
      sub(/Status:\*\*[[:space:]]*[^[:space:]<]+/, "Status:** " new)
      updated=1
      print; next
    }
    { print }
    END { if (!updated) exit 2 }
  ' "$master" > "$tmp" || { rm -f "$tmp"; return 2; }
  mv "$tmp" "$master"
}

legacy_master_plan_append_row() {
  local legacy_id="${1:?legacy_master_plan_append_row <legacy-id> <title> <priority> <type> <source> <status>}"
  local title="${2:?}" priority="${3:?}" type="${4:?}" source="${5:?}" status="${6:?}"
  local master
  master=$(_master_plan_path) || return 2
  [ -f "$master" ] || { printf 'legacy_master_plan_append_row: missing %s\n' "$master" >&2; return 2; }

  # Idempotent — if a `### $legacy_id ` heading already exists, no-op.
  if grep -q "^### $legacy_id " "$master"; then
    return 0
  fi

  local tmp
  tmp="$master.tmp.$$"
  # Insert the new block at the end of the `## Tasks` section — just before
  # the next `## ` heading. Append to EOF when `## Tasks` is the final section.
  awk -v id="$legacy_id" -v title="$title" -v priority="$priority" -v type="$type" -v source="$source" -v status="$status" '
    BEGIN { in_tasks=0; emitted=0 }
    /^## Tasks[[:space:]]*$/ { in_tasks=1; print; next }
    in_tasks==1 && /^## / {
      printf "### %s — %s\n", id, title
      printf "- **Priority:** %s\n", priority
      printf "- **Status:** %s\n", status
      printf "- **Type:** %s\n", type
      printf "- **Source:** %s\n", source
      printf "\n"
      emitted=1
      in_tasks=0
      print; next
    }
    { print }
    END {
      if (!emitted) {
        printf "### %s — %s\n", id, title
        printf "- **Priority:** %s\n", priority
        printf "- **Status:** %s\n", status
        printf "- **Type:** %s\n", type
        printf "- **Source:** %s\n", source
        printf "\n"
      }
    }
  ' "$master" > "$tmp" || { rm -f "$tmp"; return 2; }
  mv "$tmp" "$master"
}

legacy_master_plan_archive_task() {
  # Moving a full task block from master → archive requires robust section
  # boundaries (task block may contain `####` subtasks, code fences, etc).
  # Deferred until commits 5+ land fixtures we can regression-test against.
  printf 'legacy_master_plan_archive_task: not implemented in Phase 2.6.5 commit 3 — callers must defer task archival to /chanakya compact until commit N\n' >&2
  return 9
}

legacy_inbox_move_to_processed() {
  local filename="${1:?legacy_inbox_move_to_processed <debrief-filename>}"
  local inbox
  inbox=$(_chanakya_inbox_path) || return 2
  local src="$inbox/$filename"
  local dst="$inbox/processed/$filename"
  # Idempotent — already-processed file succeeds silently.
  if [ ! -f "$src" ] && [ -f "$dst" ]; then
    return 0
  fi
  if [ ! -f "$src" ]; then
    printf 'legacy_inbox_move_to_processed: missing source %s\n' "$src" >&2
    return 2
  fi
  mkdir -p "$inbox/processed" || return 2
  mv "$src" "$dst"
}

legacy_inbox_write_debrief() {
  local legacy_id="${1:?legacy_inbox_write_debrief <legacy-id> <path> <body>}"
  local path="${2:?}" body="${3:-}"
  mkdir -p "$(dirname "$path")" || return 2
  printf '%s\n' "$body" > "$path"
}

legacy_brief_write_markdown() {
  local legacy_id="${1:?legacy_brief_write_markdown <legacy-id> <slug> <body>}"
  local slug="${2:?}" body="${3:-}"
  local project tasks_dir path
  project=$(resolve_project 2>/dev/null) || return 2
  tasks_dir="$(resolve_plans_dir_for "$project")/chanakya-tasks"
  path="$tasks_dir/${legacy_id}-${slug}.md"
  mkdir -p "$tasks_dir" || return 2
  printf '%s\n' "$body" > "$path"
}

legacy_review_write_markdown() {
  # Legacy reviews are free-form markdown under the worktree's argus scratch
  # area, not a stable studio-managed path. Writing a canonical legacy review
  # requires resolving the worktree that owns the review subject — deferred.
  printf 'legacy_review_write_markdown: not implemented in Phase 2.6.5 commit 3 — callers must limit to YAML-only until commit N\n' >&2
  return 9
}

legacy_round_write_markdown() {
  local round_num="${1:?legacy_round_write_markdown <round-number> <body>}"
  local body="${2:-}"
  local project rounds_dir path
  project=$(resolve_project 2>/dev/null) || return 2
  rounds_dir="$(resolve_plans_dir_for "$project")/user-testing-rounds"
  path="$rounds_dir/user-testing-round${round_num}.md"
  mkdir -p "$rounds_dir" || return 2
  printf '%s\n' "$body" > "$path"
}

legacy_release_log_append() {
  local build="${1:?legacy_release_log_append <build> <version> <type> <date> <tag> <head> <tasks-csv>}"
  local version="${2:?}" type="${3:?}" date_str="${4:?}" tag="${5:?}" head="${6:-}" tasks_csv="${7:-}"
  local master
  master=$(_master_plan_path) || return 2
  [ -f "$master" ] || { printf 'legacy_release_log_append: missing %s\n' "$master" >&2; return 2; }

  # Idempotent — if the Tag already appears in the Release Log, no-op.
  if grep -F "| $tag |" "$master" 2>/dev/null | grep -q .; then
    return 0
  fi

  # Append a new row right before the next `## ` heading after `## Release Log`.
  # Row shape matches master-plan.md §Release Log.
  local tasks_cell="${tasks_csv//,/, }"
  local tmp
  tmp="$master.tmp.$$"
  awk -v build="$build" -v version="$version" -v type="$type" -v date="$date_str" \
      -v tag="$tag" -v head="$head" -v tasks="$tasks_cell" '
    BEGIN { in_log=0; emitted=0 }
    /^## Release Log/ { in_log=1; print; next }
    in_log==1 && /^## / {
      printf "| %s | %s | %s | %s | %s | %s | %s |\n", build, version, type, date, tag, head, tasks
      emitted=1
      in_log=0
      print; next
    }
    { print }
    END {
      if (!emitted && in_log==1) {
        printf "| %s | %s | %s | %s | %s | %s | %s |\n", build, version, type, date, tag, head, tasks
      } else if (!emitted) {
        printf "\n## Release Log\n\n"
        printf "| Build | Version | Type | Date | Tag | HEAD | Tasks Included |\n"
        printf "|-------|---------|------|------|-----|------|---------------|\n"
        printf "| %s | %s | %s | %s | %s | %s | %s |\n", build, version, type, date, tag, head, tasks
      }
    }
  ' "$master" > "$tmp" || { rm -f "$tmp"; return 2; }
  mv "$tmp" "$master"
}
