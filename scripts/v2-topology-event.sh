#!/usr/bin/env bash
# Emit typed Studio v2 topology runtime telemetry through the durable event log.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REGISTRY="$REPO_ROOT/core/v2/topology/runtime-failures.yaml"
SCHEMA="$REPO_ROOT/core/v2/schemas/topology-runtime-event.schema.json"

COMMAND="${1:-}"
[ -n "$COMMAND" ] && shift || true

RUNTIME_ROOT=""
FAILURE_MODE=""
SUBJECT=""
PRODUCER_ROLE=""
DATA_JSON=""
OCCURRED_AT=""
QUIET=0

usage() {
  cat >&2 <<'USAGE'
usage:
  scripts/v2-topology-event.sh emit --runtime-root <dir> --failure-mode <mode> --subject <ref> --producer-role <role> --data-json <json> [--occurred-at <iso8601>] [--quiet]
USAGE
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

parse_emit_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --runtime-root=*) RUNTIME_ROOT="${1#--runtime-root=}"; shift ;;
      --runtime-root) RUNTIME_ROOT="${2:?--runtime-root requires dir}"; shift 2 ;;
      --failure-mode=*) FAILURE_MODE="${1#--failure-mode=}"; shift ;;
      --failure-mode) FAILURE_MODE="${2:?--failure-mode requires value}"; shift 2 ;;
      --subject=*) SUBJECT="${1#--subject=}"; shift ;;
      --subject) SUBJECT="${2:?--subject requires value}"; shift 2 ;;
      --producer-role=*) PRODUCER_ROLE="${1#--producer-role=}"; shift ;;
      --producer-role) PRODUCER_ROLE="${2:?--producer-role requires value}"; shift 2 ;;
      --data-json=*) DATA_JSON="${1#--data-json=}"; shift ;;
      --data-json) DATA_JSON="${2:?--data-json requires JSON}"; shift 2 ;;
      --occurred-at=*) OCCURRED_AT="${1#--occurred-at=}"; shift ;;
      --occurred-at) OCCURRED_AT="${2:?--occurred-at requires value}"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'v2-topology-event: unknown arg: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
  done
}

require_tools() {
  command -v jq >/dev/null 2>&1 || {
    printf 'v2-topology-event: jq is required\n' >&2
    exit 3
  }
  command -v yq >/dev/null 2>&1 || {
    printf 'v2-topology-event: yq is required\n' >&2
    exit 3
  }
  command -v check-jsonschema >/dev/null 2>&1 || {
    printf 'v2-topology-event: check-jsonschema is required\n' >&2
    exit 3
  }
}

registry_row_json() {
  FAILURE_MODE="$FAILURE_MODE" yq -o=json '.failure_modes[] | select(.mode == strenv(FAILURE_MODE))' "$REGISTRY" 2>/dev/null
}

hash_key() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf 'v2-topology-event: shasum or sha256sum required\n' >&2
    exit 3
  fi
}

cmd_emit() {
  parse_emit_args "$@"
  require_tools

  [ -n "$RUNTIME_ROOT" ] || { usage; exit 2; }
  [ -n "$FAILURE_MODE" ] || { usage; exit 2; }
  [ -n "$SUBJECT" ] || { usage; exit 2; }
  [ -n "$PRODUCER_ROLE" ] || { usage; exit 2; }
  [ -n "$DATA_JSON" ] || { usage; exit 2; }

  local row event severity required_fields missing data event_json tmp id_hash
  row=$(registry_row_json)
  if [ -z "$row" ]; then
    printf 'v2-topology-event: unknown failure mode: %s\n' "$FAILURE_MODE" >&2
    exit 2
  fi
  event=$(printf '%s\n' "$row" | jq -r '.event')
  severity=$(printf '%s\n' "$row" | jq -r '.severity_floor')
  required_fields=$(printf '%s\n' "$row" | jq -c '.required_data')

  data=$(printf '%s' "$DATA_JSON" | jq -c \
    --arg failure_mode "$FAILURE_MODE" \
    --arg severity_floor "$severity" \
    '. + {
      failure_mode: $failure_mode,
      severity_floor: $severity_floor,
      privacy_classification: "private-runtime"
    }') || {
    printf 'v2-topology-event: --data-json is invalid JSON\n' >&2
    exit 2
  }

  missing=$(printf '%s\n' "$data" | jq -r --argjson required "$required_fields" '
    ($required - keys_unsorted) | join(",")
  ') || exit 2
  if [ -n "$missing" ]; then
    printf 'v2-topology-event: missing required data field(s) for %s: %s\n' "$FAILURE_MODE" "$missing" >&2
    exit 2
  fi

  [ -n "$OCCURRED_AT" ] || OCCURRED_AT=$(now_utc)
  id_hash=$(hash_key "$SUBJECT|$FAILURE_MODE|$OCCURRED_AT|$data")
  event_json=$(jq -n \
    --arg event "$event" \
    --arg occurred_at "$OCCURRED_AT" \
    --arg producer "$PRODUCER_ROLE" \
    --arg subject "$SUBJECT" \
    --arg idempotency_key "topology:$SUBJECT:$FAILURE_MODE:$id_hash" \
    --argjson data "$data" \
    '{
      schema_version: 1,
      event: $event,
      occurred_at: $occurred_at,
      producer: {agent: $producer, mode: "topology-runtime"},
      subject: $subject,
      idempotency_key: $idempotency_key,
      writable_action: true,
      data: $data
    }')

  tmp=$(mktemp -t v2-topology-event.XXXXXX) || exit 2
  printf '%s\n' "$event_json" > "$tmp"
  if ! PYTHONWARNINGS=ignore check-jsonschema --schemafile "$SCHEMA" "$tmp" >/dev/null; then
    rm -f "$tmp"
    printf 'v2-topology-event: event failed schema validation\n' >&2
    exit 2
  fi
  rm -f "$tmp"

  if [ "$QUIET" -eq 1 ]; then
    "$SCRIPT_DIR/v2-event-log.sh" append --runtime-root "$RUNTIME_ROOT" --quiet --event-json "$event_json"
  else
    "$SCRIPT_DIR/v2-event-log.sh" append --runtime-root "$RUNTIME_ROOT" --event-json "$event_json"
  fi
}

case "$COMMAND" in
  emit) cmd_emit "$@" ;;
  -h|--help|"") usage; [ -n "$COMMAND" ] && exit 0 || exit 2 ;;
  *) printf 'v2-topology-event: unknown command: %s\n' "$COMMAND" >&2; usage; exit 2 ;;
esac
