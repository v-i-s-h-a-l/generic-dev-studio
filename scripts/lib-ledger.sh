#!/usr/bin/env bash
# lib-ledger.sh — sourced library for ledger mutations.
#
# Every script that mutates a plans/<kind>/ artifact routes through these
# helpers. Post-#245 (Stage A.4/A.5) the library is YAML-only — the dual-write
# transition closed when legacy debrief-shaped surfaces moved under
# plans/.legacy-archive/. The dual-write call sites in the writers below have
# been removed; the legacy_*_helpers (lower in this file) now fail loud as a
# safety net for any straggler caller.
#
# History: Phase 2.6 introduced the structured YAML layer; Phase 2.6.5 commit
# 3 wired this library as the single mutation surface; #245 A.3 flipped
# DUAL_WRITE_MODE default → yaml-only; #245 A.4/A.5 archived legacy surfaces
# and removed the dual-write code paths entirely. See
# _shared/patterns/dual-write-transition.md for the pattern (kept as a
# primitive for any future migration).
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
#   State transitions (YAML-only post-#245 A.5)
#     transition_task_state    <uuid> <to> <actor> <reason>
#     transition_brief_state   <uuid> <to> <actor> <reason>
#     transition_release_state <uuid> <to> <actor> <reason>
#     transition_review_state  <uuid> <to> <actor> <reason>
#     transition_round_state   <uuid> <to> <actor> <reason>
#
#   Link mutations (task-side; no events — callers emit)
#     set_task_link         <uuid> <brief|debrief|release> <target-uuid>
#     append_task_link      <uuid> <reviews|feedback>      <target-uuid>
#     set_task_touchpoints  <uuid> <path...>               annotation; bumps updated_at + index
#
#   Artifact writers (YAML + event; no legacy markdown post-#245 A.5)
#     write_task_artifact     <uuid> <state> <title> [k=v...]
#     write_brief_artifact    <brief-uuid> <task-uuid> <type> <size> [k=v...]
#     write_debrief_artifact  <uuid> <task-uuid|null> <brief-uuid|null> <mode> <state> [k=v...]
#     write_review_artifact   <uuid> <subject-kind> <subject-uuid> <verdict> <findings-json>
#     write_round_artifact    <uuid> <round-number> <scope> <tasks-csv> <body>
#     write_release_artifact  <uuid> <channel> <version> <build> <tag> <tasks-csv>
#
#   Legacy counterpart helpers (RETIRED — fail loud on call)
#     legacy_master_plan_set_status / append_row / archive_task
#     legacy_inbox_move_to_processed / write_debrief
#     legacy_brief_write_markdown / legacy_review_write_markdown
#     legacy_round_write_markdown / legacy_release_log_append
#
#   Batching
#     flush_index                             rebuild plans/index.yaml now
#
# Env controls (all optional):
#   DRY_RUN           `1` to log + buffer without filesystem writes
#   WITHHOLD_INDEX    `1` to skip rebuild-index per mutation (callers batch)
#
# (DUAL_WRITE_MODE is no longer consulted post-#245 A.5 — readers are gone.)
#
# Exit codes:
#   0   success
#   2   validation error (unknown kind, missing file, malformed input)
#   9   retired legacy helper called (see _legacy_helper_retired)
#
# No `set -e` — sourced into scripts that may or may not want strict mode.

# Script dir resolves so relative sources (rebuild-index.sh) work even when
# caller is invoked from another cwd.
LEDGER_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# shellcheck source=lib-paths.sh
. "$LEDGER_LIB_DIR/lib-paths.sh" 2>/dev/null || true

# Load per-project env overrides (e.g. DUAL_WRITE_MODE during the #245 A.2 soak).
# No-op outside a project; safe to call repeatedly.
_lp_load_project_env 2>/dev/null || true

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

  # OTel GenAI semantic convention attributes (contracts/events.md §OTel GenAI conformance).
  # STUDIO_HOST is set by the spawning process (hooks/session-start, H8); default claude-code.
  local otel_system otel_agent_name otel_op_name
  otel_system="${STUDIO_HOST:-claude-code}"
  otel_agent_name="$agent"
  case "$event" in
    *handoff*)                        otel_op_name="handoff" ;;
    agent_boot|agent_session_completed) otel_op_name="create_agent" ;;
    *)                                otel_op_name="invoke_agent" ;;
  esac

  # Build envelope. `producer` is always present; `idempotency_key` only if set
  # (session-lifecycle events per contracts/event-emission.md §2 omit it).
  # OTel attrs are always top-level for third-party dashboard compatibility.
  if [ -n "$idem" ]; then
    line=$(printf '{"ts":"%s","agent":"%s","event":"%s","task":"%s","data":%s,"producer":{"agent":"%s","mode":"%s","instance_id":"%s"},"idempotency_key":"%s","gen_ai.system":"%s","gen_ai.agent.name":"%s","gen_ai.operation.name":"%s"}' \
      "$ts" \
      "$(_json_escape "$agent")" \
      "$(_json_escape "$event")" \
      "$(_json_escape "$task")" \
      "$data" \
      "$(_json_escape "$agent")" \
      "$(_json_escape "$mode")" \
      "$(_json_escape "$instance_id")" \
      "$(_json_escape "$idem")" \
      "$(_json_escape "$otel_system")" \
      "$(_json_escape "$otel_agent_name")" \
      "$(_json_escape "$otel_op_name")")
  else
    line=$(printf '{"ts":"%s","agent":"%s","event":"%s","task":"%s","data":%s,"producer":{"agent":"%s","mode":"%s","instance_id":"%s"},"gen_ai.system":"%s","gen_ai.agent.name":"%s","gen_ai.operation.name":"%s"}' \
      "$ts" \
      "$(_json_escape "$agent")" \
      "$(_json_escape "$event")" \
      "$(_json_escape "$task")" \
      "$data" \
      "$(_json_escape "$agent")" \
      "$(_json_escape "$mode")" \
      "$(_json_escape "$instance_id")" \
      "$(_json_escape "$otel_system")" \
      "$(_json_escape "$otel_agent_name")" \
      "$(_json_escape "$otel_op_name")")
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

set_release_asc_poll() {
  local uuid="${1:?set_release_asc_poll <release-uuid> <asc-state> <last-poll> <next-check> <failures> <stuck>}"
  local asc_state="${2:?}" last_poll="${3:?}" next_check="${4:?}" failures="${5:-0}" stuck="${6:-false}"
  local f
  f=$(_artifact_path releases "$uuid") || return 2
  [ -f "$f" ] || { printf 'set_release_asc_poll: no release at %s\n' "$f" >&2; return 2; }

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "asc_metadata.app_store_state=$asc_state" "$(idem_key chanakya release "$uuid" "asc-poll:$asc_state:$last_poll")"
  else
    yq -i \
      ".last_state_checked_at = \"$last_poll\" |
       .asc_metadata.app_store_state = \"$asc_state\" |
       .asc_metadata.last_poll_at = \"$last_poll\" |
       .asc_metadata.next_check_at = \"$next_check\" |
       .asc_metadata.consecutive_failures = $failures |
       .asc_metadata.stuck = $stuck" \
      "$f" 2>/dev/null || return 2
  fi
  _maybe_rebuild_index
}

set_release_asc_failure() {
  local uuid="${1:?set_release_asc_failure <release-uuid> <reason> <last-poll> <next-check> <failures> <stuck>}"
  local reason="${2:?}" last_poll="${3:?}" next_check="${4:?}" failures="${5:-1}" stuck="${6:-false}"
  local f
  f=$(_artifact_path releases "$uuid") || return 2
  [ -f "$f" ] || { printf 'set_release_asc_failure: no release at %s\n' "$f" >&2; return 2; }

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "asc_metadata.failure=$reason" "$(idem_key chanakya release "$uuid" "asc-failure:$reason:$last_poll")"
  else
    yq -i \
      ".last_state_checked_at = \"$last_poll\" |
       .asc_metadata.last_poll_at = \"$last_poll\" |
       .asc_metadata.next_check_at = \"$next_check\" |
       .asc_metadata.consecutive_failures = $failures |
       .asc_metadata.stuck = $stuck |
       .asc_metadata.last_error = \"$reason\"" \
      "$f" 2>/dev/null || return 2
  fi
  _maybe_rebuild_index
}

set_release_finalize_progress() {
  local uuid="${1:?set_release_finalize_progress <release-uuid> <field> <value>}"
  local field="${2:?}" value="${3:?}"
  case "$field" in
    finalize_draft_published|finalize_slack_posted|finalize_slack_skipped_reason) ;;
    *) printf 'set_release_finalize_progress: unsupported field %s\n' "$field" >&2; return 2 ;;
  esac
  local f
  f=$(_artifact_path releases "$uuid") || return 2
  [ -f "$f" ] || { printf 'set_release_finalize_progress: no release at %s\n' "$f" >&2; return 2; }

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "asc_metadata.$field=$value" "$(idem_key chanakya release "$uuid" "finalize:$field:$value")"
  else
    if [ "$value" = "true" ] || [ "$value" = "false" ]; then
      yq -i ".asc_metadata.$field = $value" "$f" 2>/dev/null || return 2
    else
      yq -i ".asc_metadata.$field = \"$value\"" "$f" 2>/dev/null || return 2
    fi
  fi
  _maybe_rebuild_index
}

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
    reopened)           printf 'pending' ;;
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

# Annotate task with file-path globs the task is expected to touch.
# Not a state transition — no event emitted. Bumps updated_at + rebuilds index.
# Usage: set_task_touchpoints <task-uuid> <path1> [<path2> ...]
set_task_touchpoints() {
  local uuid="${1:?set_task_touchpoints <task-uuid> <path...>}"
  shift
  local f
  f=$(_artifact_path tasks "$uuid") || return 2
  [ -f "$f" ] || { printf 'set_task_touchpoints: no task at %s\n' "$f" >&2; return 2; }
  local ts arr sep
  ts=$(iso_ts_now)
  arr="["; sep=""
  for p in "$@"; do arr="${arr}${sep}$(yaml_quote "$p")"; sep=", "; done
  arr="${arr}]"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "affinity.touchpoints=$arr" "set_task_touchpoints:$uuid"
    return 0
  fi
  yq -i ".affinity.touchpoints = $arr | .updated_at = \"$ts\"" "$f" 2>/dev/null || return 2
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

# Separates `body=<inline>` / `body_file=<path>` pairs from the rest of the
# args. Sets globals (arrays are painful across bash function boundaries):
#   _LW_BODY       — resolved inline body content (empty if neither given)
#   _LW_REST_ARGS  — remaining pairs, safe to pass through _append_kv_lines
# `body_file=` takes precedence when both are provided; file-based form lets
# callers pass multi-KB markdown without shell-arg bloat or re-escaping.
_extract_body_and_rest() {
  _LW_BODY=""
  _LW_REST_ARGS=()
  local _p _bf
  for _p in "$@"; do
    case "$_p" in
      body=*)      _LW_BODY="${_p#body=}" ;;
      body_file=*) _bf="${_p#body_file=}"
                   if [ -n "$_bf" ] && [ -f "$_bf" ]; then
                     _LW_BODY=$(cat "$_bf")
                   fi ;;
      *)           _LW_REST_ARGS+=("$_p") ;;
    esac
  done
}

# Emits `body: |` block-scalar (indented 2 spaces) when body is non-empty;
# no-op otherwise. _append_kv_lines can't produce block-scalar form — flat
# yaml_quote on multi-line content produces YAML that round-trips wrong, so
# body is special-cased.
_emit_body_block() {
  local _b="${1:-}"
  [ -z "$_b" ] && return 0
  printf 'body: |\n%s\n' "$(printf '%s' "$_b" | sed 's/^/  /')"
}

# ---------- Artifact writers ----------
#
# Same shape as _transition_artifact: write YAML first, then emit the event.

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

  # Body (multi-line prose) is special-cased as block-scalar YAML in the
  # canonical file.
  # body_file=<path> lets callers pass large renders without shell-arg bloat.
  _extract_body_and_rest "$@"

  # Resolve legacy_task_id from the parent task YAML when not passed
  # explicitly as a k=v arg (#296). Guarantees every brief carries the
  # field regardless of caller discipline.
  local _has_legacy_tid=0
  local _kv
  for _kv in "${_LW_REST_ARGS[@]+"${_LW_REST_ARGS[@]}"}"; do
    case "$_kv" in legacy_task_id=*) _has_legacy_tid=1; break ;; esac
  done
  if [ "$_has_legacy_tid" -eq 0 ] && command -v yq >/dev/null 2>&1; then
    local _project _tasks_dir _task_file _resolved_ltid
    _project=$(resolve_project 2>/dev/null) || true
    if [ -n "$_project" ]; then
      _tasks_dir=$(resolve_tasks_dir_for "$_project")
      _task_file="$_tasks_dir/${task_uuid}.yaml"
      if [ -r "$_task_file" ]; then
        _resolved_ltid=$(yq -r '.legacy_task_id // ""' "$_task_file" 2>/dev/null || echo "")
        if [ -n "$_resolved_ltid" ]; then
          _LW_REST_ARGS+=("legacy_task_id=$_resolved_ltid")
        fi
      fi
    fi
  fi

  local f ts
  f=$(_artifact_path briefs "$uuid") || return 2
  ts=$(iso_ts_now)
  local idem
  idem=$(idem_key chanakya brief "$uuid" "task=$task_uuid;type=$type;size=$size")

  local payload
  payload=$({
    printf 'schema_version: {name: brief, version: 3.5.0, min_reader: 3.0.0, deprecated_at: null}\n'
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
    _append_kv_lines "${_LW_REST_ARGS[@]+"${_LW_REST_ARGS[@]}"}"
    _emit_body_block "$_LW_BODY"
  })

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "$payload" "$idem"
  else
    _atomic_write "$f" "$payload" || return 2
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

  # Same body-as-block-scalar treatment as write_brief_artifact. See notes on
  # _extract_body_and_rest / _emit_body_block above.
  _extract_body_and_rest "$@"

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
    _append_kv_lines "${_LW_REST_ARGS[@]+"${_LW_REST_ARGS[@]}"}"
    _emit_body_block "$_LW_BODY"
  })

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "$payload" "$idem"
  else
    # Validate debrief payload against the JSON Schema contract before writing.
    # Rejections never auto-retry — per idempotency.md §Per-step retry classification.
    local _validate_tmp
    _validate_tmp=$(mktemp "${TMPDIR:-/tmp}/validate-debrief-XXXXXX")
    printf '%s\n' "$payload" > "$_validate_tmp"
    if ! "$SCRIPT_DIR/validate-contract.sh" debrief "$_validate_tmp" 2>&1; then
      rm -f "$_validate_tmp"
      return 2
    fi
    rm -f "$_validate_tmp"
    _atomic_write "$f" "$payload" || return 2
  fi

  local data
  if [ -n "$_report_state" ]; then
    data=$(printf '{"mode":"%s","state":"%s","report_state":"%s"}' \
      "$(_json_escape "$mode")" "$(_json_escape "$state")" "$(_json_escape "$_report_state")")
  else
    data=$(printf '{"mode":"%s","state":"%s"}' "$(_json_escape "$mode")" "$(_json_escape "$state")")
  fi
  # Event `task` field: direct-debrief sessions (task_uuid=null) carry a
  # synthetic `direct:<debrief-uuid>` id so `debrief_emitted` is joinable by
  # `task` uniformly across modes instead of landing as the empty string. See
  # issue #87. Task-mode debriefs retain the debrief UUID as the event key
  # (same as the idempotency key) to avoid touching a separate concern.
  local event_task="$uuid"
  if [ "$task_uuid" = "null" ] || [ -z "$task_uuid" ]; then
    event_task="direct:$uuid"
  fi
  emit_event_keyed achilles debrief debrief_emitted "$event_task" "$data" --idem-key "$idem" >/dev/null || return $?
  _maybe_rebuild_index
}

write_review_artifact() {
  local uuid="${1:?write_review_artifact <uuid> <subject-kind> <subject-uuid> <verdict> <findings-json> [stage]}"
  local subject_kind="${2:?}" subject_uuid="${3:?}" verdict="${4:?}" findings_json="${5:-[]}"
  local stage="${6:-quality}"
  case "$stage" in
    spec|quality) ;;
    *) printf 'lib-ledger: invalid stage=%s (want spec|quality)\n' "$stage" >&2; return 2 ;;
  esac

  local f ts
  f=$(_artifact_path reviews "$uuid") || return 2
  ts=$(iso_ts_now)
  local idem
  idem=$(idem_key argus review "$subject_uuid" "verdict=$verdict;stage=$stage")

  local payload
  payload=$({
    printf 'schema_version: {name: review, version: 1.1.0, min_reader: 1.0.0, deprecated_at: null}\n'
    printf 'id: %s\n' "$uuid"
    printf 'subject: {kind: %s, id: %s}\n' "$subject_kind" "$subject_uuid"
    printf 'reviewer: argus\n'
    printf 'stage: %s\n' "$stage"
    printf 'state: %s\n' "$verdict"
    printf 'requested_at: %s\n' "$ts"
    printf 'completed_at: %s\n' "$ts"
    printf 'verdict: %s\n' "$verdict"
    printf 'findings: %s\n' "$findings_json"
    printf 'checks_run: []\n'
    printf 'scope: {diff_size: 0, file_count: 0, caps_triggered: []}\n'
    printf 'notes: null\n'
    printf 'idempotency_key: "%s"\n' "$idem"
  })

  if [ "${DRY_RUN:-0}" = "1" ]; then
    _dry_write_log "$f" "$payload" "$idem"
  else
    # Validate verdict payload against the JSON Schema contract before writing.
    # Rejections never auto-retry — per idempotency.md §Per-step retry classification.
    local _validate_tmp
    _validate_tmp=$(mktemp "${TMPDIR:-/tmp}/validate-verdict-XXXXXX")
    printf '%s\n' "$payload" > "$_validate_tmp"
    if ! "$SCRIPT_DIR/validate-contract.sh" review-verdict "$_validate_tmp" 2>&1; then
      rm -f "$_validate_tmp"
      return 2
    fi
    rm -f "$_validate_tmp"
    _atomic_write "$f" "$payload" || return 2
  fi

  local data
  data=$(printf '{"subject_kind":"%s","subject_uuid":"%s","verdict":"%s","stage":"%s"}' \
    "$(_json_escape "$subject_kind")" "$(_json_escape "$subject_uuid")" "$(_json_escape "$verdict")" "$(_json_escape "$stage")")
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

  local data
  data=$(printf '{"from":null,"to":"released","channel":"%s","tag":"%s"}' \
    "$(_json_escape "$channel")" "$(_json_escape "$tag")")
  emit_event_keyed achilles release release_state_changed "$uuid" "$data" --idem-key "$idem" >/dev/null || return $?
  _maybe_rebuild_index
}

# ---------- Legacy counterpart helpers (RETIRED — #245 A.4/A.5) ----------
#
# Phase 2.6 dual-write window closed when #245 archived legacy debrief-shaped
# surfaces under plans/.legacy-archive/ and removed every internal call site.
# These function names remain so any straggler caller (out-of-tree script,
# stale mode-pack example, backfill tool against an unarchived project) fails
# loud with a clear pointer instead of NameError-degenerating to silence.
#
# To re-enable any of these (e.g. a future migration that needs a markdown
# bridge): rebuild from `git show <pre-A.4-sha>:scripts/lib-ledger.sh` —
# the legacy implementations are preserved in history, not in the working tree.

_legacy_helper_retired() {
  local fn="$1"
  printf '%s: legacy markdown surface retired by #245 (Stage A.4/A.5).\n' "$fn" >&2
  printf '  Call site is stale. New writers must target plans/<kind>/*.yaml only.\n' >&2
  printf '  See _shared/primitives/file-locations.md and _shared/patterns/dual-write-transition.md.\n' >&2
  return 9
}

legacy_master_plan_set_status()    { _legacy_helper_retired legacy_master_plan_set_status; }
legacy_master_plan_append_row()    { _legacy_helper_retired legacy_master_plan_append_row; }
legacy_master_plan_archive_task()  { _legacy_helper_retired legacy_master_plan_archive_task; }
legacy_inbox_move_to_processed()   { _legacy_helper_retired legacy_inbox_move_to_processed; }
legacy_inbox_write_debrief()       { _legacy_helper_retired legacy_inbox_write_debrief; }
legacy_brief_write_markdown()      { _legacy_helper_retired legacy_brief_write_markdown; }
legacy_review_write_markdown()     { _legacy_helper_retired legacy_review_write_markdown; }
legacy_round_write_markdown()      { _legacy_helper_retired legacy_round_write_markdown; }
legacy_release_log_append()        { _legacy_helper_retired legacy_release_log_append; }

# ---------- Build-debt YAML (Stage A.0 / #273) ----------
#
# Canonical source for the build-debt counter is plans/build-debt.yaml. The
# `## Build Debt` section in chanakya-master.md is a render projection produced
# by scripts/render-master-plan.sh. Schema: _shared/schemas/build-debt.md.
#
# Pre-#273 projects keep mutating master-plan inline (sweep-ingest.sh's awk
# blocks) under the dual-write window; the YAML helpers below run alongside so
# both surfaces stay coherent through the soak. Post-A.3 the master-plan
# mutations no-op and the projector regenerates the markdown from YAML.

build_debt_path() {
  local project
  project=$(resolve_project 2>/dev/null) || return 2
  printf '%s\n' "$(resolve_plans_dir_for "$project")/build-debt.yaml"
}

build_debt_init() {
  local f
  f=$(build_debt_path) || return 2
  [ -f "$f" ] && return 0
  mkdir -p "$(dirname "$f")" || return 2
  local ts
  ts=$(iso_ts_now)
  cat > "$f" <<EOF
schema_version: {name: build-debt, version: 1.0.0, min_reader: 1.0.0, deprecated_at: null}
counter: 0
state: silent
warn_at: 6
block_at: 12
last_green: null
last_green_sha: null
unverified_since: []
broken_commit_sha: null
open_check_task: null
blocked_by: null
next_tbuild_n: 1
notes: null
updated_at: $ts
EOF
}

# Read a single field. Defaults to "counter". Empty stdout when YAML missing or
# yq unavailable; callers gate on emptiness.
build_debt_get() {
  local field="${1:-counter}"
  local f
  f=$(build_debt_path) || return 0
  [ -f "$f" ] || return 0
  command -v yq >/dev/null 2>&1 || return 0
  yq -r ".${field} // \"\"" "$f" 2>/dev/null
}

# Apply a yq mutation expression. Auto-creates the file if missing. Always
# bumps updated_at.
_build_debt_yq_apply() {
  local expr="${1:?_build_debt_yq_apply <yq-expression>}"
  local f
  f=$(build_debt_path) || return 2
  build_debt_init || return 2
  command -v yq >/dev/null 2>&1 || { printf 'build_debt: yq required\n' >&2; return 2; }
  local ts
  ts=$(iso_ts_now)
  yq -i "${expr} | .updated_at = \"${ts}\"" "$f" 2>/dev/null || return 2
}

_build_debt_state_for_counter() {
  local counter="${1:-0}" warn_at="${2:-6}" block_at="${3:-12}"
  if [ "$counter" -ge "$block_at" ]; then printf 'block\n'
  elif [ "$counter" -ge "$warn_at" ]; then printf 'warn\n'
  else printf 'silent\n'
  fi
}

# Reset on green build-check. Clears unverified_since, broken_commit_sha,
# blocked_by, open_check_task. Sets last_green/last_green_sha. State → silent.
build_debt_reset_green() {
  local last_green="${1:-}" last_sha="${2:-}"
  local lg_expr=".last_green = null"
  local lgs_expr=".last_green_sha = null"
  if [ -n "$last_green" ]; then lg_expr=".last_green = \"$(_json_escape "$last_green")\""; fi
  if [ -n "$last_sha" ]; then lgs_expr=".last_green_sha = \"$(_json_escape "$last_sha")\""; fi
  _build_debt_yq_apply ".counter = 0 | .state = \"silent\" | .unverified_since = [] | .broken_commit_sha = null | .blocked_by = null | .open_check_task = null | ${lg_expr} | ${lgs_expr}"
}

# Increment on lsp-only debrief or red build-check. Optionally append a task-id
# to unverified_since. State recomputed from new counter.
build_debt_increment() {
  local task_id="${1:-}" overridden="${2:-0}"
  build_debt_init || return 2
  local cur warn_at block_at
  cur=$(build_debt_get counter); cur=${cur:-0}
  warn_at=$(build_debt_get warn_at); warn_at=${warn_at:-6}
  block_at=$(build_debt_get block_at); block_at=${block_at:-12}
  local new_counter=$(( cur + 1 ))
  local new_state
  new_state=$(_build_debt_state_for_counter "$new_counter" "$warn_at" "$block_at")
  local append_expr=""
  if [ -n "$task_id" ]; then
    local entry="$task_id"
    [ "$overridden" = "1" ] && entry="${task_id}[overridden]"
    append_expr=" | .unverified_since += [\"$(_json_escape "$entry")\"]"
  fi
  _build_debt_yq_apply ".counter = ${new_counter} | .state = \"${new_state}\"${append_expr}"
}

# Annotate a red build-check: increment counter, set broken_commit_sha,
# blocked_by, force state=block (red builds block regardless of counter).
build_debt_annotate_red() {
  local broken_sha="${1:-unknown}" blocked_by="${2:-TBUILD-fix}"
  build_debt_init || return 2
  local cur
  cur=$(build_debt_get counter); cur=${cur:-0}
  local new_counter=$(( cur + 1 ))
  _build_debt_yq_apply ".counter = ${new_counter} | .state = \"block\" | .broken_commit_sha = \"$(_json_escape "$broken_sha")\" | .blocked_by = \"$(_json_escape "$blocked_by")\""
}

# Allocate the next TBUILD-N legacy id atomically. Prints the integer N and
# bumps next_tbuild_n in the YAML.
build_debt_allocate_tbuild_n() {
  build_debt_init || return 2
  local n
  n=$(build_debt_get next_tbuild_n); n=${n:-1}
  _build_debt_yq_apply ".next_tbuild_n = $(( n + 1 ))" || return 2
  printf '%s\n' "$n"
}
