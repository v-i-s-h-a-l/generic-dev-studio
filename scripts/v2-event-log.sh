#!/usr/bin/env bash
# v2-event-log.sh - durable Studio v2 event-log append and subscriber replay.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

COMMAND="${1:-}"
[ -n "$COMMAND" ] && shift || true

RUNTIME_ROOT=""
PROJECT=""
EVENT_JSON=""
SUBSCRIBER=""
HANDLER=""
MALFORMED="block"
WARNING_BYTES=1048576
CRITICAL_BYTES=10485760
WRITE_STATUS=0
QUIET=0

usage() {
  cat <<'EOF'
Usage:
  scripts/v2-event-log.sh append --runtime-root <dir> --event-json <json>
  scripts/v2-event-log.sh replay --runtime-root <dir> --subscriber <name> [--handler <cmd>] [--malformed block|dead-letter]
  scripts/v2-event-log.sh lag --runtime-root <dir> --subscriber <name> [--warning-bytes N] [--critical-bytes N] [--write-status]

Runtime layout:
  <runtime-root>/events/YYYY-MM-DD.jsonl
  <runtime-root>/.runtime/v2/subscribers/<name>.checkpoint.json
  <runtime-root>/.runtime/v2/subscribers/<name>.dedupe/<sha256>
  <runtime-root>/.runtime/v2/dead-letter/<name>/*.json
EOF
  exit 2
}

json_quote() {
  jq -Rn --arg v "$1" '$v'
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

hash_key() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf 'v2-event-log.sh: shasum or sha256sum required for subscriber dedupe\n' >&2
    exit 2
  fi
}

resolve_runtime_root() {
  if [ -n "$RUNTIME_ROOT" ]; then
    printf '%s\n' "$RUNTIME_ROOT"
    return 0
  fi
  if [ -n "$PROJECT" ]; then
    resolve_project_root_for "$PROJECT"
    return $?
  fi
  local project
  project=$(resolve_project 2>/dev/null) || return 1
  resolve_project_root_for "$project"
}

checkpoint_path() {
  local root="$1" subscriber="$2"
  printf '%s/.runtime/v2/subscribers/%s.checkpoint.json\n' "$root" "$subscriber"
}

checkpoint_dir() {
  local root="$1"
  printf '%s/.runtime/v2/subscribers\n' "$root"
}

dedupe_dir() {
  local root="$1" subscriber="$2"
  printf '%s/.runtime/v2/subscribers/%s.dedupe\n' "$root" "$subscriber"
}

dead_letter_dir() {
  local root="$1" subscriber="$2"
  printf '%s/.runtime/v2/dead-letter/%s\n' "$root" "$subscriber"
}

atomic_write() {
  local path="$1" tmp
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    return 1
  fi
  mkdir -p "$(dirname "$path")" || return 1
  tmp="${path}.$$.$RANDOM.tmp"
  cat > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$path" || {
    rm -f "$tmp"
    return 1
  }
}

ensure_subscriber_state_writable() {
  local root="$1" subscriber="$2" checkpoint_probe dedupe_probe
  checkpoint_probe="$(checkpoint_dir "$root")/.write-check.$$.$RANDOM"
  dedupe_probe="$(dedupe_dir "$root" "$subscriber")/.write-check.$$.$RANDOM"

  mkdir -p "$(checkpoint_dir "$root")" "$(dedupe_dir "$root" "$subscriber")" || return 1
  printf '' > "$checkpoint_probe" || return 1
  rm -f "$checkpoint_probe" || return 1
  printf '' > "$dedupe_probe" || return 1
  rm -f "$dedupe_probe" || return 1
}

write_checkpoint() {
  local root="$1" subscriber="$2" shard="$3" offset="$4" event_id="${5:-}"
  local path
  path=$(checkpoint_path "$root" "$subscriber")
  jq -n \
    --arg subscriber "$subscriber" \
    --arg shard "$shard" \
    --argjson next_byte_offset "$offset" \
    --arg updated_at "$(now_utc)" \
    --arg last_event_id "$event_id" \
    '{
      schema_version: 1,
      subscriber: $subscriber,
      shard: $shard,
      next_byte_offset: $next_byte_offset,
      updated_at: $updated_at,
      last_event_id: (if $last_event_id == "" then null else $last_event_id end)
    }' | atomic_write "$path"
}

first_shard() {
  find "$1/events" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jsonl' 2>/dev/null | sort | head -n 1
}

last_shard() {
  find "$1/events" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jsonl' 2>/dev/null | sort | tail -n 1
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --runtime-root=*) RUNTIME_ROOT="${1#--runtime-root=}"; shift ;;
      --runtime-root) RUNTIME_ROOT="${2:?--runtime-root requires dir}"; shift 2 ;;
      --project=*) PROJECT="${1#--project=}"; shift ;;
      --project) PROJECT="${2:?--project requires slug}"; shift 2 ;;
      --event-json=*) EVENT_JSON="${1#--event-json=}"; shift ;;
      --event-json) EVENT_JSON="${2:?--event-json requires JSON}"; shift 2 ;;
      --subscriber=*) SUBSCRIBER="${1#--subscriber=}"; shift ;;
      --subscriber) SUBSCRIBER="${2:?--subscriber requires name}"; shift 2 ;;
      --handler=*) HANDLER="${1#--handler=}"; shift ;;
      --handler) HANDLER="${2:?--handler requires command}"; shift 2 ;;
      --malformed=*) MALFORMED="${1#--malformed=}"; shift ;;
      --malformed) MALFORMED="${2:?--malformed requires block|dead-letter}"; shift 2 ;;
      --warning-bytes=*) WARNING_BYTES="${1#--warning-bytes=}"; shift ;;
      --warning-bytes) WARNING_BYTES="${2:?--warning-bytes requires N}"; shift 2 ;;
      --critical-bytes=*) CRITICAL_BYTES="${1#--critical-bytes=}"; shift ;;
      --critical-bytes) CRITICAL_BYTES="${2:?--critical-bytes requires N}"; shift 2 ;;
      --write-status) WRITE_STATUS=1; shift ;;
      --quiet) QUIET=1; shift ;;
      -h|--help) usage ;;
      *) printf 'v2-event-log.sh: unknown arg: %s\n' "$1" >&2; usage ;;
    esac
  done
}

validate_name() {
  case "$1" in
    ""|*/*|*..*|*[^A-Za-z0-9._-]*)
      printf 'v2-event-log.sh: invalid subscriber name: %s\n' "$1" >&2
      exit 2
      ;;
  esac
}

cmd_append() {
  parse_args "$@"
  command -v jq >/dev/null 2>&1 || { printf 'v2-event-log.sh: jq required\n' >&2; exit 2; }
  [ -n "$EVENT_JSON" ] || EVENT_JSON=$(cat)

  local root line bytes occurred shard events_dir path
  root=$(resolve_runtime_root) || {
    printf 'v2-event-log.sh: could not resolve runtime root\n' >&2
    exit 2
  }

  line=$(printf '%s' "$EVENT_JSON" | jq -c '
    if type != "object" then error("event must be a JSON object") else . end
    | if ((.event // "") | type == "string" and length > 0) then . else error("event string is required") end
    | if has("occurred_at") then . else . + {occurred_at: now | todateiso8601} end
    | if has("data") then . else . + {data: {}} end
  ') || {
    printf 'v2-event-log.sh: invalid event JSON\n' >&2
    exit 2
  }
  bytes=$(printf '%s' "$line" | wc -c | tr -d ' ')
  if [ "$bytes" -gt 4096 ]; then
    printf 'v2-event-log.sh: event exceeds 4096-byte durable append budget (%s)\n' "$bytes" >&2
    exit 3
  fi
  occurred=$(printf '%s\n' "$line" | jq -r '.occurred_at')
  shard=${occurred%%T*}
  case "$shard" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) shard=$(date -u +%Y-%m-%d) ;;
  esac

  events_dir="$root/events"
  mkdir -p "$events_dir" || {
    printf 'v2-event-log.sh: could not create events directory: %s\n' "$events_dir" >&2
    exit 1
  }
  path="$events_dir/$shard.jsonl"
  printf '%s\n' "$line" >> "$path" || {
    printf 'v2-event-log.sh: append failed: %s\n' "$path" >&2
    exit 1
  }
  [ "$QUIET" -eq 1 ] || printf '%s\n' "$path"
}

line_dead_letter() {
  local root="$1" subscriber="$2" shard="$3" offset="$4" reason="$5" line="$6"
  local dir path
  dir=$(dead_letter_dir "$root" "$subscriber")
  mkdir -p "$dir" || return 1
  path="$dir/${shard%.jsonl}-$offset.json"
  jq -n \
    --arg subscriber "$subscriber" \
    --arg shard "$shard" \
    --argjson byte_offset "$offset" \
    --arg reason "$reason" \
    --arg line_excerpt "$(printf '%s' "$line" | cut -c 1-500)" \
    --arg created_at "$(now_utc)" \
    '{
      schema_version: 1,
      subscriber: $subscriber,
      shard: $shard,
      byte_offset: $byte_offset,
      reason: $reason,
      line_excerpt: $line_excerpt,
      created_at: $created_at
    }' | atomic_write "$path" || return 1
  printf '%s\n' "$path"
}

write_dedupe_marker() {
  local root="$1" subscriber="$2" path="$3" shard="$4" offset="$5" producer="$6" idem="$7"
  mkdir -p "$(dedupe_dir "$root" "$subscriber")" || {
    printf 'v2-event-log.sh: dedupe directory write failed for %s\n' "$subscriber" >&2
    return 1
  }
  printf '%s\t%s\t%s\t%s\n' "$shard" "$offset" "$producer" "$idem" > "$path" || {
    printf 'v2-event-log.sh: dedupe write failed for %s\n' "$subscriber" >&2
    return 1
  }
}

process_line() {
  local root="$1" subscriber="$2" shard="$3" offset="$4" next_offset="$5" line="$6"
  local event_id producer idem dedupe_key dedupe_path out

  if ! printf '%s\n' "$line" | jq -e 'type == "object" and ((.event // "") | type == "string" and length > 0)' >/dev/null 2>&1; then
    line_dead_letter "$root" "$subscriber" "$shard" "$offset" "malformed_json" "$line" >/dev/null || {
      printf 'v2-event-log.sh: dead-letter write failed at %s:%s\n' "$shard" "$offset" >&2
      return 1
    }
    if [ "$MALFORMED" = "dead-letter" ]; then
      write_checkpoint "$root" "$subscriber" "$shard" "$next_offset" "" || {
        printf 'v2-event-log.sh: checkpoint write failed for %s\n' "$subscriber" >&2
        return 1
      }
      return 0
    fi
    printf 'v2-event-log.sh: malformed event at %s:%s\n' "$shard" "$offset" >&2
    return 1
  fi

  producer=$(printf '%s\n' "$line" | jq -r '.producer.agent // .agent // ""')
  idem=$(printf '%s\n' "$line" | jq -r '.idempotency_key // ""')
  if [ -n "$idem" ]; then
    dedupe_key=$(hash_key "$producer|$idem")
    dedupe_path="$(dedupe_dir "$root" "$subscriber")/$dedupe_key"
    if [ -e "$dedupe_path" ] && [ ! -f "$dedupe_path" ]; then
      printf 'v2-event-log.sh: dedupe marker path is not a file for %s\n' "$subscriber" >&2
      return 1
    fi
    if [ -f "$dedupe_path" ]; then
      write_checkpoint "$root" "$subscriber" "$shard" "$next_offset" "" || {
        printf 'v2-event-log.sh: checkpoint write failed for %s\n' "$subscriber" >&2
        return 1
      }
      return 0
    fi
  fi

  event_id=$(printf '%s\n' "$line" | jq -r '.event_id // .id // ""')
  out=$(printf '%s\n' "$line" | jq -c \
    --arg shard "$shard" \
    --argjson byte_offset "$offset" \
    '. + {replay: {shard: $shard, byte_offset: $byte_offset}}')

  if [ -n "$HANDLER" ]; then
    printf '%s\n' "$out" | sh -c "$HANDLER" || return 1
    if [ -n "$idem" ]; then
      write_dedupe_marker "$root" "$subscriber" "$dedupe_path" "$shard" "$offset" "$producer" "$idem" || return 1
    fi
    write_checkpoint "$root" "$subscriber" "$shard" "$next_offset" "$event_id" || {
      printf 'v2-event-log.sh: checkpoint write failed for %s\n' "$subscriber" >&2
      return 1
    }
    return 0
  fi

  if [ -n "$idem" ]; then
    write_dedupe_marker "$root" "$subscriber" "$dedupe_path" "$shard" "$offset" "$producer" "$idem" || return 1
  fi
  write_checkpoint "$root" "$subscriber" "$shard" "$next_offset" "$event_id" || {
    printf 'v2-event-log.sh: checkpoint write failed for %s\n' "$subscriber" >&2
    return 1
  }
  if [ "$QUIET" -ne 1 ]; then
    printf '%s\n' "$out"
  fi
}

cmd_replay() {
  parse_args "$@"
  command -v jq >/dev/null 2>&1 || { printf 'v2-event-log.sh: jq required\n' >&2; exit 2; }
  [ -n "$SUBSCRIBER" ] || { printf 'v2-event-log.sh: --subscriber is required\n' >&2; exit 2; }
  validate_name "$SUBSCRIBER"
  case "$MALFORMED" in block|dead-letter) ;; *) printf 'v2-event-log.sh: --malformed must be block or dead-letter\n' >&2; exit 2 ;; esac

  local root cp shard offset shard_path start_seen f base size last_char line line_bytes next_offset processed_any
  root=$(resolve_runtime_root) || {
    printf 'v2-event-log.sh: could not resolve runtime root\n' >&2
    exit 2
  }
  ensure_subscriber_state_writable "$root" "$SUBSCRIBER" || {
    printf 'v2-event-log.sh: subscriber state is not writable for %s\n' "$SUBSCRIBER" >&2
    exit 1
  }
  cp=$(checkpoint_path "$root" "$SUBSCRIBER")
  if [ -e "$cp" ] && [ ! -f "$cp" ]; then
    printf 'v2-event-log.sh: checkpoint path is not a file: %s\n' "$cp" >&2
    exit 1
  fi

  if [ -f "$cp" ]; then
    shard=$(jq -er '.shard | select(type == "string" and length > 0)' "$cp" 2>/dev/null) || {
      printf 'v2-event-log.sh: invalid checkpoint: %s\n' "$cp" >&2
      exit 1
    }
    offset=$(jq -er '.next_byte_offset | select(type == "number" and . >= 0 and floor == .)' "$cp" 2>/dev/null) || {
      printf 'v2-event-log.sh: invalid checkpoint: %s\n' "$cp" >&2
      exit 1
    }
    case "$shard" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jsonl) ;;
      *)
        printf 'v2-event-log.sh: invalid checkpoint: %s\n' "$cp" >&2
        exit 1
        ;;
    esac
    [ -f "$root/events/$shard" ] || {
      printf 'v2-event-log.sh: checkpoint shard missing: %s\n' "$shard" >&2
      exit 1
    }
  else
    shard_path=$(first_shard "$root")
    [ -n "$shard_path" ] || exit 0
    shard=$(basename "$shard_path")
    offset=0
  fi

  start_seen=0
  while IFS= read -r f; do
    base=$(basename "$f")
    if [ "$start_seen" -eq 0 ]; then
      [ "$base" = "$shard" ] || continue
      start_seen=1
    fi
    size=$(wc -c < "$f" | tr -d ' ')
    if [ "$base" = "$shard" ] && [ "$offset" -gt "$size" ]; then
      printf 'v2-event-log.sh: checkpoint offset past EOF: %s:%s > %s\n' "$base" "$offset" "$size" >&2
      exit 1
    fi
    if [ "$size" -gt 0 ]; then
      last_char=$(tail -c 1 "$f")
      if [ "$last_char" != "" ]; then
        line_dead_letter "$root" "$SUBSCRIBER" "$base" "$offset" "partial_final_line" "" >/dev/null || {
          printf 'v2-event-log.sh: dead-letter write failed at %s:%s\n' "$base" "$offset" >&2
          exit 1
        }
        printf 'v2-event-log.sh: partial final line in %s\n' "$base" >&2
        exit 1
      fi
    fi

    processed_any=0
    while IFS= read -r line; do
      line_bytes=$(printf '%s\n' "$line" | wc -c | tr -d ' ')
      next_offset=$((offset + line_bytes))
      process_line "$root" "$SUBSCRIBER" "$base" "$offset" "$next_offset" "$line" || exit $?
      offset="$next_offset"
      processed_any=1
    done < <(tail -c +"$((offset + 1))" "$f")

    if [ "$processed_any" -eq 0 ]; then
      write_checkpoint "$root" "$SUBSCRIBER" "$base" "$offset" "" || {
        printf 'v2-event-log.sh: checkpoint write failed for %s\n' "$SUBSCRIBER" >&2
        exit 1
      }
    fi
    offset=0
  done < <(find "$root/events" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jsonl' 2>/dev/null | sort)
}

cmd_lag() {
  parse_args "$@"
  command -v jq >/dev/null 2>&1 || { printf 'v2-event-log.sh: jq required\n' >&2; exit 2; }
  [ -n "$SUBSCRIBER" ] || { printf 'v2-event-log.sh: --subscriber is required\n' >&2; exit 2; }
  validate_name "$SUBSCRIBER"

  local root cp last last_base cp_shard cp_offset cp_size pending oldest f base size severity status_path status
  root=$(resolve_runtime_root) || {
    printf 'v2-event-log.sh: could not resolve runtime root\n' >&2
    exit 2
  }
  cp=$(checkpoint_path "$root" "$SUBSCRIBER")
  if [ -e "$cp" ] && [ ! -f "$cp" ]; then
    printf 'v2-event-log.sh: checkpoint path is not a file: %s\n' "$cp" >&2
    exit 1
  fi
  last=$(last_shard "$root")
  if [ -z "$last" ]; then
    status=$(jq -n --arg subscriber "$SUBSCRIBER" --arg updated_at "$(now_utc)" \
      '{schema_version: 1, subscriber: $subscriber, updated_at: $updated_at, pending_bytes: 0, severity: "ok", oldest_unprocessed_shard: null}')
    if [ "$WRITE_STATUS" -eq 1 ]; then
      status_path="$(checkpoint_dir "$root")/$SUBSCRIBER.lag.json"
      printf '%s\n' "$status" | atomic_write "$status_path" || {
        printf 'v2-event-log.sh: lag status write failed: %s\n' "$status_path" >&2
        exit 1
      }
    fi
    printf '%s\n' "$status"
    return 0
  fi
  last_base=$(basename "$last")
  if [ -f "$cp" ]; then
    cp_shard=$(jq -er '.shard | select(type == "string" and length > 0)' "$cp" 2>/dev/null) || {
      printf 'v2-event-log.sh: invalid checkpoint: %s\n' "$cp" >&2
      exit 1
    }
    cp_offset=$(jq -er '.next_byte_offset | select(type == "number" and . >= 0 and floor == .)' "$cp" 2>/dev/null) || {
      printf 'v2-event-log.sh: invalid checkpoint: %s\n' "$cp" >&2
      exit 1
    }
    case "$cp_shard" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jsonl) ;;
      *)
        printf 'v2-event-log.sh: invalid checkpoint: %s\n' "$cp" >&2
        exit 1
        ;;
    esac
    [ -f "$root/events/$cp_shard" ] || {
      printf 'v2-event-log.sh: checkpoint shard missing: %s\n' "$cp_shard" >&2
      exit 1
    }
    cp_size=$(wc -c < "$root/events/$cp_shard" | tr -d ' ')
    if [ "$cp_offset" -gt "$cp_size" ]; then
      printf 'v2-event-log.sh: checkpoint offset past EOF: %s:%s > %s\n' "$cp_shard" "$cp_offset" "$cp_size" >&2
      exit 1
    fi
  else
    cp_shard=$(basename "$(first_shard "$root")")
    cp_offset=0
  fi

  pending=0
  oldest=""
  while IFS= read -r f; do
    base=$(basename "$f")
    [ "$base" \< "$cp_shard" ] && continue
    size=$(wc -c < "$f" | tr -d ' ')
    if [ "$base" = "$cp_shard" ]; then
      [ "$cp_offset" -lt "$size" ] || continue
      pending=$((pending + size - cp_offset))
    else
      pending=$((pending + size))
    fi
    [ -n "$oldest" ] || oldest="$base"
  done < <(find "$root/events" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jsonl' 2>/dev/null | sort)

  severity="ok"
  [ "$pending" -ge "$WARNING_BYTES" ] && severity="warning"
  [ "$pending" -ge "$CRITICAL_BYTES" ] && severity="critical"

  status=$(jq -n \
    --arg subscriber "$SUBSCRIBER" \
    --arg checkpoint_shard "$cp_shard" \
    --argjson checkpoint_offset "$cp_offset" \
    --arg latest_shard "$last_base" \
    --argjson pending_bytes "$pending" \
    --arg oldest_unprocessed_shard "$oldest" \
    --arg severity "$severity" \
    --arg updated_at "$(now_utc)" \
    '{
      schema_version: 1,
      subscriber: $subscriber,
      checkpoint: {shard: $checkpoint_shard, next_byte_offset: $checkpoint_offset},
      latest_shard: $latest_shard,
      pending_bytes: $pending_bytes,
      oldest_unprocessed_shard: (if $oldest_unprocessed_shard == "" then null else $oldest_unprocessed_shard end),
      severity: $severity,
      updated_at: $updated_at
    }')
  if [ "$WRITE_STATUS" -eq 1 ]; then
    status_path="$(checkpoint_dir "$root")/$SUBSCRIBER.lag.json"
    printf '%s\n' "$status" | atomic_write "$status_path" || {
      printf 'v2-event-log.sh: lag status write failed: %s\n' "$status_path" >&2
      exit 1
    }
  fi
  printf '%s\n' "$status"
}

case "$COMMAND" in
  append) cmd_append "$@" ;;
  replay) cmd_replay "$@" ;;
  lag) cmd_lag "$@" ;;
  -h|--help|"") usage ;;
  *) printf 'v2-event-log.sh: unknown command: %s\n' "$COMMAND" >&2; usage ;;
esac
