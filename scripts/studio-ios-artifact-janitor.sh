#!/usr/bin/env bash
# studio-ios-artifact-janitor.sh - retention and cleanup for scoped iOS artifacts.

set -euo pipefail
umask 022

MODE="${1:-}"
[ -n "$MODE" ] || {
  printf 'usage: studio-ios-artifact-janitor.sh <finalize-operation|record-quarantine|sweep|complete-chain> [flags]\n' >&2
  exit 2
}
shift || true

ROOT=""
BASE=""
SUMMARY_PATH=""
RESULT_BUNDLE_PATH=""
LOG_PATH=""
TMP_PATH=""
DERIVED_DATA_PATH=""
QUARANTINE_PATH=""
OPERATION=""
ATTEMPT=""
ISSUE_RUN_ID=""
CACHE_KEY=""
REASON=""
CHAIN_STATUS="completed"
EXIT_CODE=0
DRY_RUN_FLAG="${DRY_RUN:-0}"
NOW_EPOCH="${STUDIO_IOS_JANITOR_NOW_EPOCH:-}"

usage() {
  cat >&2 <<'EOF'
usage:
  studio-ios-artifact-janitor.sh finalize-operation --root <dir> --summary <path> --result-bundle <path> --log <path> --tmp <path> --derived-data <path> --exit-code <n> --operation <name> --attempt <id> --issue-run-id <id> [--json] [--dry-run]
  studio-ios-artifact-janitor.sh record-quarantine --root <dir> --quarantine <path> --cache-key <key> --reason <reason> [--issue-run-id <id>] [--attempt <id>] [--json]
  studio-ios-artifact-janitor.sh sweep --root <dir>|--base <dir> [--json] [--dry-run]
  studio-ios-artifact-janitor.sh complete-chain --root <dir> [--status completed|failed|blocked|aborted|release] [--json] [--dry-run]
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root requires a path}"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    --base) BASE="${2:?--base requires a path}"; shift 2 ;;
    --base=*) BASE="${1#--base=}"; shift ;;
    --summary) SUMMARY_PATH="${2:?--summary requires a path}"; shift 2 ;;
    --summary=*) SUMMARY_PATH="${1#--summary=}"; shift ;;
    --result-bundle) RESULT_BUNDLE_PATH="${2:?--result-bundle requires a path}"; shift 2 ;;
    --result-bundle=*) RESULT_BUNDLE_PATH="${1#--result-bundle=}"; shift ;;
    --log) LOG_PATH="${2:?--log requires a path}"; shift 2 ;;
    --log=*) LOG_PATH="${1#--log=}"; shift ;;
    --tmp) TMP_PATH="${2:?--tmp requires a path}"; shift 2 ;;
    --tmp=*) TMP_PATH="${1#--tmp=}"; shift ;;
    --derived-data) DERIVED_DATA_PATH="${2:?--derived-data requires a path}"; shift 2 ;;
    --derived-data=*) DERIVED_DATA_PATH="${1#--derived-data=}"; shift ;;
    --quarantine) QUARANTINE_PATH="${2:?--quarantine requires a path}"; shift 2 ;;
    --quarantine=*) QUARANTINE_PATH="${1#--quarantine=}"; shift ;;
    --operation) OPERATION="${2:?--operation requires a value}"; shift 2 ;;
    --operation=*) OPERATION="${1#--operation=}"; shift ;;
    --attempt) ATTEMPT="${2:?--attempt requires a value}"; shift 2 ;;
    --attempt=*) ATTEMPT="${1#--attempt=}"; shift ;;
    --issue-run-id) ISSUE_RUN_ID="${2:?--issue-run-id requires a value}"; shift 2 ;;
    --issue-run-id=*) ISSUE_RUN_ID="${1#--issue-run-id=}"; shift ;;
    --cache-key) CACHE_KEY="${2:?--cache-key requires a value}"; shift 2 ;;
    --cache-key=*) CACHE_KEY="${1#--cache-key=}"; shift ;;
    --reason) REASON="${2:?--reason requires a value}"; shift 2 ;;
    --reason=*) REASON="${1#--reason=}"; shift ;;
    --status) CHAIN_STATUS="${2:?--status requires a value}"; shift 2 ;;
    --status=*) CHAIN_STATUS="${1#--status=}"; shift ;;
    --exit-code) EXIT_CODE="${2:?--exit-code requires a value}"; shift 2 ;;
    --exit-code=*) EXIT_CODE="${1#--exit-code=}"; shift ;;
    --now-epoch) NOW_EPOCH="${2:?--now-epoch requires a value}"; shift 2 ;;
    --now-epoch=*) NOW_EPOCH="${1#--now-epoch=}"; shift ;;
    --json) shift ;;
    --dry-run) DRY_RUN_FLAG=1; shift ;;
    -h|--help) usage ;;
    *) printf 'studio-ios-artifact-janitor: unexpected argument: %s\n' "$1" >&2; usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  printf 'studio-ios-artifact-janitor: jq is required\n' >&2
  exit 2
}

case "$MODE" in
  finalize-operation|record-quarantine|sweep|complete-chain) ;;
  *) printf 'studio-ios-artifact-janitor: unknown mode: %s\n' "$MODE" >&2; usage ;;
esac

case "$NOW_EPOCH" in
  ''|*[!0-9]*) NOW_EPOCH=$(date -u +%s) ;;
esac

deleted_count=0
retained_count=0
pinned_count=0
compressed_count=0
skipped_count=0
quarantined_count=0
refused_count=0
bytes_freed=0
roots_seen=0
status="completed"
status_reason=""

positive_int_or_default() {
  local value="$1" fallback="$2"
  case "$value" in
    ''|*[!0-9]*|0) printf '%s\n' "$fallback" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

safe_segment() {
  local value="${1:-unknown}" safe
  safe=$(printf '%s' "$value" | sed 's/[^A-Za-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
  [ -n "$safe" ] || safe="unknown"
  printf '%s\n' "$safe"
}

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print $1}'
  fi
}

root_hash() {
  printf '%s' "$1" | hash_text | cut -c1-16
}

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

epoch_to_iso() {
  local epoch="$1"
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s\n' "$(iso_now)"
}

iso_to_epoch() {
  local value="$1"
  case "$value" in
    ''|null) return 1 ;;
    *[!0-9]*)
      date -u -j -f %Y-%m-%dT%H:%M:%SZ "$value" +%s 2>/dev/null \
        || date -u -d "$value" +%s 2>/dev/null \
        || return 1
      ;;
    *) printf '%s\n' "$value" ;;
  esac
}

mtime_epoch() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0'
}

size_bytes() {
  local target="$1"
  if [ -f "$target" ]; then
    stat -f %z "$target" 2>/dev/null || stat -c %s "$target" 2>/dev/null || printf '0'
  elif [ -d "$target" ]; then
    du -sk "$target" 2>/dev/null | awk '{print $1 * 1024}'
  else
    printf '0'
  fi
}

canonical_existing_or_parent() {
  local path="$1" parent
  if [ -e "$path" ]; then
    (cd "$(dirname "$path")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")")
  else
    parent=$(dirname "$path")
    [ -d "$parent" ] || return 1
    (cd "$parent" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")")
  fi
}

path_under_root() {
  local root="$1" path="$2" canonical_root canonical_path
  [ -n "$root" ] || return 1
  [ -n "$path" ] || return 1
  [ -d "$root" ] || return 1
  canonical_root=$(cd "$root" && pwd -P) || return 1
  canonical_path=$(canonical_existing_or_parent "$path") || return 1
  case "$canonical_path" in
    "$canonical_root"|"$canonical_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

delete_path() {
  local root="$1" target="$2" freed
  [ -n "$target" ] || return 0
  if [ ! -e "$target" ]; then
    if [ -e "$target.gz" ]; then
      target="$target.gz"
    elif [ -e "$target.tgz" ]; then
      target="$target.tgz"
    else
      skipped_count=$((skipped_count + 1))
      return 0
    fi
  fi
  if ! path_under_root "$root" "$target"; then
    skipped_count=$((skipped_count + 1))
    return 0
  fi
  freed=$(size_bytes "$target")
  if [ "$DRY_RUN_FLAG" = "1" ]; then
    deleted_count=$((deleted_count + 1))
    bytes_freed=$((bytes_freed + freed))
    return 0
  fi
  rm -rf "$target" 2>/dev/null || {
    skipped_count=$((skipped_count + 1))
    return 0
  }
  deleted_count=$((deleted_count + 1))
  bytes_freed=$((bytes_freed + freed))
}

delete_root() {
  local root="$1" canonical freed
  [ -d "$root" ] || return 0
  canonical=$(cd "$root" && pwd -P) || return 0
  case "$canonical" in
    /|"$HOME"|"$HOME"/.dev-studio|"$HOME"/.dev-studio/.runtime)
      skipped_count=$((skipped_count + 1))
      return 0
      ;;
  esac
  freed=$(size_bytes "$root")
  if [ "$DRY_RUN_FLAG" = "1" ]; then
    deleted_count=$((deleted_count + 1))
    bytes_freed=$((bytes_freed + freed))
    return 0
  fi
  rm -rf "$root" 2>/dev/null || {
    skipped_count=$((skipped_count + 1))
    return 0
  }
  deleted_count=$((deleted_count + 1))
  bytes_freed=$((bytes_freed + freed))
}

compress_if_large() {
  local root="$1" target="$2" min_bytes size parent base
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  path_under_root "$root" "$target" || {
    skipped_count=$((skipped_count + 1))
    return 0
  }
  min_bytes=$(positive_int_or_default "${STUDIO_IOS_ARTIFACT_COMPRESS_MIN_BYTES:-1048576}" 1048576)
  size=$(size_bytes "$target")
  [ "$size" -ge "$min_bytes" ] || return 0
  if [ -f "$target" ] && command -v gzip >/dev/null 2>&1; then
    if [ "$DRY_RUN_FLAG" = "1" ]; then
      compressed_count=$((compressed_count + 1))
      return 0
    fi
    gzip -f "$target" 2>/dev/null && compressed_count=$((compressed_count + 1))
  elif [ -d "$target" ] && [ "${STUDIO_IOS_ARTIFACT_COMPRESS_RESULT_BUNDLES:-0}" = "1" ] && command -v tar >/dev/null 2>&1; then
    parent=$(dirname "$target")
    base=$(basename "$target")
    if [ "$DRY_RUN_FLAG" = "1" ]; then
      compressed_count=$((compressed_count + 1))
      return 0
    fi
    tar -czf "$target.tgz" -C "$parent" "$base" 2>/dev/null && rm -rf "$target" && compressed_count=$((compressed_count + 1))
  fi
}

free_disk_json() {
  local root="$1" probe line free_kb total_kb free_pct min_kb min_pct pressure
  probe="$root"
  [ -e "$probe" ] || probe=$(dirname "$root")
  [ -e "$probe" ] || probe="${TMPDIR:-/tmp}"
  line=$(df -Pk "$probe" 2>/dev/null | awk 'NR == 2 {print $2 "\t" $4}')
  total_kb=$(printf '%s\n' "$line" | awk '{print $1}')
  free_kb=$(printf '%s\n' "$line" | awk '{print $2}')
  case "$total_kb" in ''|*[!0-9]*) total_kb=0 ;; esac
  case "$free_kb" in ''|*[!0-9]*) free_kb=0 ;; esac
  if [ "$total_kb" -gt 0 ]; then
    free_pct=$(( free_kb * 100 / total_kb ))
  else
    free_pct=0
  fi
  min_kb=$(positive_int_or_default "${STUDIO_IOS_ARTIFACT_MIN_FREE_KB:-0}" 0)
  min_pct=$(positive_int_or_default "${STUDIO_IOS_ARTIFACT_MIN_FREE_PCT:-0}" 0)
  pressure=false
  if { [ "$min_kb" -gt 0 ] && [ "$free_kb" -lt "$min_kb" ]; } || { [ "$min_pct" -gt 0 ] && [ "$free_pct" -lt "$min_pct" ]; }; then
    pressure=true
  fi
  jq -cn \
    --argjson free_kb "$free_kb" \
    --argjson total_kb "$total_kb" \
    --argjson free_pct "$free_pct" \
    --argjson min_free_kb "$min_kb" \
    --argjson min_free_pct "$min_pct" \
    --argjson pressure "$pressure" \
    '{free_kb:$free_kb,total_kb:$total_kb,free_pct:$free_pct,min_free_kb:$min_free_kb,min_free_pct:$min_free_pct,pressure:$pressure}'
}

check_disk_pressure_or_refuse() {
  local root="$1" disk
  disk=$(free_disk_json "$root")
  if jq -e '.pressure == true' >/dev/null 2>&1 <<EOF
$disk
EOF
  then
    status="refused_disk_pressure"
    status_reason="disk pressure threshold not satisfied"
    refused_count=$((refused_count + 1))
    release_lock "$root"
    emit_telemetry "$root"
    exit 75
  fi
}

lock_path_for_root() {
  printf '%s/.studio-ios-janitor.lock\n' "$1"
}

lock_is_stale() {
  local lock="$1" pid created now age stale_sec
  stale_sec=$(positive_int_or_default "${STUDIO_IOS_ARTIFACT_LOCK_STALE_SEC:-1800}" 1800)
  [ -f "$lock/pid" ] || return 0
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    created=$(mtime_epoch "$lock")
    now="$NOW_EPOCH"
    age=$(( now - created ))
    [ "$age" -gt "$stale_sec" ] && return 0
    return 1
  fi
  return 0
}

acquire_lock() {
  local root="$1" lock
  mkdir -p "$root"
  lock=$(lock_path_for_root "$root")
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    printf '%s\n' "$(iso_now)" > "$lock/created_at"
    return 0
  fi
  if lock_is_stale "$lock"; then
    rm -rf "$lock"
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock/pid"
      printf '%s\n' "$(iso_now)" > "$lock/created_at"
      return 0
    fi
  fi
  status="locked"
  status_reason="janitor lock already held"
  skipped_count=$((skipped_count + 1))
  emit_telemetry "$root"
  exit 0
}

release_lock() {
  local root="$1" lock
  [ -n "$root" ] || return 0
  lock=$(lock_path_for_root "$root")
  [ -d "$lock" ] || return 0
  if [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$lock"
  fi
}

ttl_seconds_for_class() {
  case "$1" in
    pass-summary-only) printf '0\n' ;;
    pass-short-retain) printf '%s\n' "$(( $(positive_int_or_default "${STUDIO_IOS_ARTIFACT_PASS_SHORT_TTL_HOURS:-24}" 24) * 3600 ))" ;;
    failed-retain) printf '%s\n' "$(( $(positive_int_or_default "${STUDIO_IOS_ARTIFACT_FAILED_TTL_HOURS:-48}" 48) * 3600 ))" ;;
    blocked-retain) printf '%s\n' "$(( $(positive_int_or_default "${STUDIO_IOS_ARTIFACT_BLOCKED_TTL_HOURS:-48}" 48) * 3600 ))" ;;
    aborted-retain) printf '%s\n' "$(( $(positive_int_or_default "${STUDIO_IOS_ARTIFACT_ABORTED_TTL_HOURS:-24}" 24) * 3600 ))" ;;
    release-retain) printf '%s\n' "$(( $(positive_int_or_default "${STUDIO_IOS_ARTIFACT_RELEASE_TTL_DAYS:-30}" 30) * 86400 ))" ;;
    cache-quarantined) printf '%s\n' "$(( $(positive_int_or_default "${STUDIO_IOS_ARTIFACT_CACHE_QUARANTINE_TTL_HOURS:-168}" 168) * 3600 ))" ;;
    debug-pinned) printf '0\n' ;;
    *) printf '%s\n' "$((48 * 3600))" ;;
  esac
}

validate_debug_pin() {
  local expires_epoch
  if [ "${STUDIO_IOS_DEBUG_RETAIN:-0}" != "1" ] && [ "${STUDIO_IOS_ARTIFACT_RETENTION_CLASS:-}" != "debug-pinned" ]; then
    return 0
  fi
  [ -n "${STUDIO_IOS_DEBUG_RETAIN_OWNER:-}" ] || {
    printf 'studio-ios-artifact-janitor: STUDIO_IOS_DEBUG_RETAIN_OWNER is required when STUDIO_IOS_DEBUG_RETAIN=1\n' >&2
    exit 2
  }
  [ -n "${STUDIO_IOS_DEBUG_RETAIN_REASON:-}" ] || {
    printf 'studio-ios-artifact-janitor: STUDIO_IOS_DEBUG_RETAIN_REASON is required when STUDIO_IOS_DEBUG_RETAIN=1\n' >&2
    exit 2
  }
  [ -n "${STUDIO_IOS_DEBUG_RETAIN_UNTIL:-}" ] || {
    printf 'studio-ios-artifact-janitor: STUDIO_IOS_DEBUG_RETAIN_UNTIL is required when STUDIO_IOS_DEBUG_RETAIN=1\n' >&2
    exit 2
  }
  expires_epoch=$(iso_to_epoch "$STUDIO_IOS_DEBUG_RETAIN_UNTIL") || {
    printf 'studio-ios-artifact-janitor: STUDIO_IOS_DEBUG_RETAIN_UNTIL must be an epoch or UTC ISO timestamp\n' >&2
    exit 2
  }
  [ "$expires_epoch" -gt "$NOW_EPOCH" ] || {
    printf 'studio-ios-artifact-janitor: debug retention expiry must be in the future\n' >&2
    exit 2
  }
}

retention_class_for_exit() {
  case "${STUDIO_IOS_ARTIFACT_RETENTION_CLASS:-}" in
    pass-summary-only|pass-short-retain|failed-retain|blocked-retain|aborted-retain|debug-pinned|release-retain|cache-quarantined)
      printf '%s\n' "$STUDIO_IOS_ARTIFACT_RETENTION_CLASS"
      return 0
      ;;
    "") ;;
    *) printf 'studio-ios-artifact-janitor: invalid STUDIO_IOS_ARTIFACT_RETENTION_CLASS: %s\n' "$STUDIO_IOS_ARTIFACT_RETENTION_CLASS" >&2; exit 2 ;;
  esac
  case "${STUDIO_IOS_ARTIFACT_STATUS:-}" in
    blocked) printf 'blocked-retain\n'; return 0 ;;
    aborted) printf 'aborted-retain\n'; return 0 ;;
    release) printf 'release-retain\n'; return 0 ;;
  esac
  if [ "${STUDIO_IOS_DEBUG_RETAIN:-0}" = "1" ]; then
    printf 'debug-pinned\n'
  elif [ "$EXIT_CODE" = "0" ]; then
    if [ "${STUDIO_IOS_PASS_SHORT_RETAIN:-0}" = "1" ]; then
      printf 'pass-short-retain\n'
    else
      printf 'pass-summary-only\n'
    fi
  else
    printf 'failed-retain\n'
  fi
}

record_file_for() {
  local root="$1" issue="$2" attempt="$3"
  [ -n "$issue" ] || issue="standalone"
  [ -n "$attempt" ] || attempt="operation"
  printf '%s/retention/%s/%s.json\n' "$root" "$(safe_segment "$issue")" "$(safe_segment "$attempt")"
}

write_retention_record() {
  local root="$1" record="$2" class="$3" expires_at="$4" tmp_record
  mkdir -p "$(dirname "$record")"
  tmp_record="$record.tmp.$$"
  jq -n \
    --arg created_at "$(iso_now)" \
    --arg run_id "${STUDIO_RUN_ID:-${RUN_ID:-}}" \
    --arg chain_run_id "${STUDIO_CHAIN_RUN_ID:-${CHAIN_RUN_ID:-}}" \
    --arg issue_run_id "$ISSUE_RUN_ID" \
    --arg operation "$OPERATION" \
    --arg attempt "$ATTEMPT" \
    --argjson exit_code "$EXIT_CODE" \
    --arg retention_class "$class" \
    --arg expires_at "$expires_at" \
    --arg root_hash "$(root_hash "$root")" \
    --arg summary_path "$SUMMARY_PATH" \
    --arg result_bundle_path "$RESULT_BUNDLE_PATH" \
    --arg log_path "$LOG_PATH" \
    --arg tmp_path "$TMP_PATH" \
    --arg derived_data_path "$DERIVED_DATA_PATH" \
    --arg quarantine_path "$QUARANTINE_PATH" \
    --arg retention_reason "$REASON" \
    --arg debug_owner "${STUDIO_IOS_DEBUG_RETAIN_OWNER:-}" \
    --arg debug_reason "${STUDIO_IOS_DEBUG_RETAIN_REASON:-}" \
    --arg debug_until "${STUDIO_IOS_DEBUG_RETAIN_UNTIL:-}" \
    '{
      schema_version: 1,
      kind: "studio-ios-artifact-retention",
      created_at: $created_at,
      updated_at: $created_at,
      run_id: (if $run_id == "" then null else $run_id end),
      chain_run_id: (if $chain_run_id == "" then null else $chain_run_id end),
      issue_run_id: (if $issue_run_id == "" then null else $issue_run_id end),
      operation: (if $operation == "" then null else $operation end),
      operation_attempt: (if $attempt == "" then null else $attempt end),
      exit_code: $exit_code,
      retention_class: $retention_class,
      expires_at: (if $expires_at == "" then null else $expires_at end),
      root_hash: $root_hash,
      reason: (if $retention_reason == "" then null else $retention_reason end),
      summary_extracted: true,
      debug_pin: (if $retention_class == "debug-pinned" then {owner:$debug_owner, reason:$debug_reason, expires_at:$debug_until} else null end),
      paths: {
        summary_path: (if $summary_path == "" then null else $summary_path end),
        result_bundle_path: (if $result_bundle_path == "" then null else $result_bundle_path end),
        log_path: (if $log_path == "" then null else $log_path end),
        tmp_path: (if $tmp_path == "" then null else $tmp_path end),
        derived_data_path: (if $derived_data_path == "" then null else $derived_data_path end),
        quarantine_path: (if $quarantine_path == "" then null else $quarantine_path end)
      }
    }' > "$tmp_record"
  mv "$tmp_record" "$record"
}

emit_telemetry() {
  local root="${1:-}" disk root_id
  if [ -n "$root" ]; then
    root_id=$(root_hash "$root")
    disk=$(free_disk_json "$root")
  else
    root_id=null
    disk='null'
  fi
  [ "$DRY_RUN_FLAG" = "1" ] && [ "$status" = "completed" ] && status="dry_run"
  jq -cn \
    --arg created_at "$(iso_now)" \
    --arg mode "$MODE" \
    --arg status "$status" \
    --arg reason "$status_reason" \
    --arg root_hash "$root_id" \
    --argjson roots_seen "$roots_seen" \
    --argjson deleted "$deleted_count" \
    --argjson retained "$retained_count" \
    --argjson pinned "$pinned_count" \
    --argjson compressed "$compressed_count" \
    --argjson skipped "$skipped_count" \
    --argjson quarantined "$quarantined_count" \
    --argjson refused "$refused_count" \
    --argjson bytes_freed "$bytes_freed" \
    --argjson disk "$disk" \
    '{
      schema_version: 1,
      kind: "studio-ios-artifact-cleanup",
      created_at: $created_at,
      mode: $mode,
      status: $status,
      reason: (if $reason == "" then null else $reason end),
      root_hash: (if $root_hash == "null" then null else $root_hash end),
      roots_seen: $roots_seen,
      counts: {
        deleted: $deleted,
        retained: $retained,
        pinned: $pinned,
        compressed: $compressed,
        skipped: $skipped,
        quarantined: $quarantined,
        refused: $refused
      },
      bytes_freed: $bytes_freed,
      disk: $disk,
      paths_redacted: true
    }'
}

expires_at_for_class() {
  local class="$1" ttl
  if [ "$class" = "debug-pinned" ]; then
    epoch_to_iso "$(iso_to_epoch "$STUDIO_IOS_DEBUG_RETAIN_UNTIL")"
    return 0
  fi
  ttl=$(ttl_seconds_for_class "$class")
  [ "$ttl" -gt 0 ] || {
    printf '\n'
    return 0
  }
  epoch_to_iso "$(( NOW_EPOCH + ttl ))"
}

finalize_operation() {
  local class expires record
  [ -n "$ROOT" ] || usage
  [ -n "$SUMMARY_PATH" ] || usage
  case "$EXIT_CODE" in ''|*[!0-9]*) printf 'studio-ios-artifact-janitor: --exit-code must be numeric\n' >&2; exit 2 ;; esac
  mkdir -p "$ROOT"
  roots_seen=$((roots_seen + 1))
  validate_debug_pin
  acquire_lock "$ROOT"
  check_disk_pressure_or_refuse "$ROOT"
  class=$(retention_class_for_exit)
  expires=$(expires_at_for_class "$class")
  record=$(record_file_for "$ROOT" "$ISSUE_RUN_ID" "$ATTEMPT")
  write_retention_record "$ROOT" "$record" "$class" "$expires"

  case "$class" in
    pass-summary-only)
      delete_path "$ROOT" "$RESULT_BUNDLE_PATH"
      delete_path "$ROOT" "$LOG_PATH"
      delete_path "$ROOT" "$TMP_PATH"
      retained_count=$((retained_count + 2))
      ;;
    debug-pinned)
      pinned_count=$((pinned_count + 1))
      retained_count=$((retained_count + 1))
      ;;
    failed-retain|blocked-retain|aborted-retain|release-retain|pass-short-retain)
      compress_if_large "$ROOT" "$LOG_PATH"
      compress_if_large "$ROOT" "$RESULT_BUNDLE_PATH"
      retained_count=$((retained_count + 1))
      ;;
    cache-quarantined)
      quarantined_count=$((quarantined_count + 1))
      ;;
  esac
  release_lock "$ROOT"
  emit_telemetry "$ROOT"
}

record_quarantine() {
  local record expires
  [ -n "$ROOT" ] || usage
  [ -n "$QUARANTINE_PATH" ] || usage
  mkdir -p "$ROOT"
  roots_seen=$((roots_seen + 1))
  acquire_lock "$ROOT"
  check_disk_pressure_or_refuse "$ROOT"
  OPERATION="${OPERATION:-cache-quarantine}"
  ATTEMPT="${ATTEMPT:-cache-quarantine-${CACHE_KEY:-unknown}}"
  EXIT_CODE=0
  expires=$(expires_at_for_class cache-quarantined)
  record=$(record_file_for "$ROOT" "${ISSUE_RUN_ID:-cache}" "$ATTEMPT")
  write_retention_record "$ROOT" "$record" "cache-quarantined" "$expires"
  quarantined_count=$((quarantined_count + 1))
  retained_count=$((retained_count + 1))
  release_lock "$ROOT"
  emit_telemetry "$ROOT"
}

delete_paths_from_record() {
  local root="$1" record="$2" path
  while IFS= read -r path; do
    [ -n "$path" ] && [ "$path" != "null" ] || continue
    delete_path "$root" "$path"
  done <<EOF
$(jq -r '.paths | to_entries[]? | .value // empty' "$record" 2>/dev/null)
EOF
  delete_path "$root" "$record"
}

record_is_active() {
  local record="$1" class expires expires_epoch created ttl created_epoch
  class=$(jq -r '.retention_class // "failed-retain"' "$record" 2>/dev/null || printf 'failed-retain')
  expires=$(jq -r '.expires_at // empty' "$record" 2>/dev/null || true)
  if [ "$class" = "debug-pinned" ] && [ -n "$expires" ]; then
    expires_epoch=$(iso_to_epoch "$expires" 2>/dev/null || printf '0')
    [ "$expires_epoch" -gt "$NOW_EPOCH" ]
    return $?
  fi
  if [ -n "$expires" ]; then
    expires_epoch=$(iso_to_epoch "$expires" 2>/dev/null || printf '0')
    [ "$expires_epoch" -gt "$NOW_EPOCH" ]
    return $?
  fi
  created=$(jq -r '.created_at // empty' "$record" 2>/dev/null || true)
  created_epoch=$(iso_to_epoch "$created" 2>/dev/null || printf '0')
  ttl=$(ttl_seconds_for_class "$class")
  [ "$ttl" -gt 0 ] && [ "$(( created_epoch + ttl ))" -gt "$NOW_EPOCH" ]
}

sweep_one_root() {
  local root="$1" record active_records=0 any_records=0 orphan_ttl orphan_mtime orphan_age
  [ -d "$root" ] || return 0
  roots_seen=$((roots_seen + 1))
  acquire_lock "$root"
  check_disk_pressure_or_refuse "$root"

  if [ -d "$root/retention" ]; then
    while IFS= read -r record; do
      [ -n "$record" ] || continue
      any_records=1
      if record_is_active "$record"; then
        if [ "$(jq -r '.retention_class // ""' "$record" 2>/dev/null)" = "debug-pinned" ]; then
          pinned_count=$((pinned_count + 1))
        else
          retained_count=$((retained_count + 1))
        fi
        active_records=$((active_records + 1))
      else
        delete_paths_from_record "$root" "$record"
      fi
    done <<EOF
$(find "$root/retention" -type f -name '*.json' 2>/dev/null | sort)
EOF
  fi

  if [ "$MODE" = "complete-chain" ] && [ "$CHAIN_STATUS" = "completed" ] && [ "$active_records" -eq 0 ]; then
    delete_root "$root"
    return 0
  fi

  if [ "$any_records" -eq 0 ]; then
    orphan_ttl=$(( $(positive_int_or_default "${STUDIO_IOS_ARTIFACT_ORPHAN_ROOT_TTL_HOURS:-48}" 48) * 3600 ))
    orphan_mtime=$(mtime_epoch "$root")
    orphan_age=$(( NOW_EPOCH - orphan_mtime ))
    if [ "$orphan_age" -gt "$orphan_ttl" ]; then
      delete_root "$root"
      return 0
    fi
    skipped_count=$((skipped_count + 1))
  fi

  release_lock "$root"
}

sweep_mode() {
  local child
  if [ -n "$BASE" ]; then
    [ -d "$BASE" ] || {
      emit_telemetry ""
      return 0
    }
    while IFS= read -r child; do
      [ -n "$child" ] || continue
      sweep_one_root "$child"
    done <<EOF
$(find "$BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
EOF
  else
    [ -n "$ROOT" ] || usage
    sweep_one_root "$ROOT"
  fi
  emit_telemetry "${ROOT:-$BASE}"
}

case "$MODE" in
  finalize-operation) finalize_operation ;;
  record-quarantine) record_quarantine ;;
  sweep|complete-chain) sweep_mode ;;
esac
