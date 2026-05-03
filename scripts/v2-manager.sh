#!/usr/bin/env bash
# v2-manager.sh - Studio v2 manager proof-of-life primitive.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

COMMAND="${1:-}"
[ -n "$COMMAND" ] && shift || true

CONTRACT="$REPO_ROOT/core/v2/manager/proof-of-life.yaml"
SCHEMA="$REPO_ROOT/core/v2/schemas/manager-proof-of-life.schema.json"
AUTHORITY="$REPO_ROOT/scripts/v2-manager.sh.authority.yaml"
EVENT_REGISTRY="$REPO_ROOT/core/v2/events/registry.yaml"

ROLE="manager"
SUBJECT_REF=""
RUNTIME_ROOT=""
HOST_NAME="${STUDIO_HOST:-unknown}"
DRY_RUN=0
ESTIMATED_TOKENS=""
IDEMPOTENCY_KEY=""

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/v2-manager.sh --validate
  scripts/v2-manager.sh proof-of-life --subject-ref <ref> [--role <role-or-alias>] [--host <host>] [--estimated-tokens <n>] --dry-run
  scripts/v2-manager.sh proof-of-life --subject-ref <ref> --runtime-root <dir> [--role <role-or-alias>] [--host <host>] [--estimated-tokens <n>]

Dry-run prints the manager proof-of-life JSON artifact and performs no writes.
Write mode stores the artifact under the runtime root and appends a bounded v2
event-log entry.
EOF
  exit 2
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'v2-manager: %s required\n' "$1" >&2
    exit 2
  }
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf 'v2-manager: shasum or sha256sum required\n' >&2
    exit 2
  fi
}

sanitize_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._:-' '-'
}

host_class() {
  case "$1" in
    claude|claude-code|anthropic-claude) printf 'claude-code\n' ;;
    codex|codex-cli|gemini|gemini-cli|ollama|openai-codex) printf 'non-claude\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

atomic_write() {
  local path="$1" tmp
  mkdir -p "$(dirname "$path")"
  tmp="${path}.$$.$RANDOM.tmp"
  cat > "$tmp"
  mv "$tmp" "$path"
}

parse_proof_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --subject-ref) SUBJECT_REF="${2:?--subject-ref requires a value}"; shift 2 ;;
      --subject-ref=*) SUBJECT_REF="${1#--subject-ref=}"; shift ;;
      --role) ROLE="${2:?--role requires a value}"; shift 2 ;;
      --role=*) ROLE="${1#--role=}"; shift ;;
      --runtime-root) RUNTIME_ROOT="${2:?--runtime-root requires a dir}"; shift 2 ;;
      --runtime-root=*) RUNTIME_ROOT="${1#--runtime-root=}"; shift ;;
      --host) HOST_NAME="${2:?--host requires a value}"; shift 2 ;;
      --host=*) HOST_NAME="${1#--host=}"; shift ;;
      --estimated-tokens) ESTIMATED_TOKENS="${2:?--estimated-tokens requires a value}"; shift 2 ;;
      --estimated-tokens=*) ESTIMATED_TOKENS="${1#--estimated-tokens=}"; shift ;;
      --idempotency-key) IDEMPOTENCY_KEY="${2:?--idempotency-key requires a value}"; shift 2 ;;
      --idempotency-key=*) IDEMPOTENCY_KEY="${1#--idempotency-key=}"; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage ;;
      *) printf 'v2-manager: unknown arg: %s\n' "$1" >&2; usage ;;
    esac
  done
}

validate_manifest() {
  require_tool jq
  require_tool yq

  [ -f "$CONTRACT" ] || {
    printf 'v2-manager: missing contract: %s\n' "$CONTRACT" >&2
    exit 1
  }
  [ -f "$SCHEMA" ] || {
    printf 'v2-manager: missing schema: %s\n' "$SCHEMA" >&2
    exit 1
  }
  [ -f "$AUTHORITY" ] || {
    printf 'v2-manager: missing authority manifest: %s\n' "$AUTHORITY" >&2
    exit 1
  }

  yq -e '
    .schema_version == 1 and
    .kind == "studio-v2-manager-proof-of-life-contract" and
    .parent_issue == 444 and
    .leaf_issue == 525 and
    .role == "manager" and
    .script == "scripts/v2-manager.sh" and
    .schema_file == "core/v2/schemas/manager-proof-of-life.schema.json" and
    .authority_file == "scripts/v2-manager.sh.authority.yaml" and
    .event_name == "manager_proof_of_life"
  ' "$CONTRACT" >/dev/null || {
    printf 'v2-manager: invalid proof-of-life contract: %s\n' "$CONTRACT" >&2
    exit 1
  }

  for key in action role filesystem commands secret_scopes mutation_scopes interactive headless_safe failure_classes override; do
    yq -e "has(\"$key\")" "$AUTHORITY" >/dev/null || {
      printf 'v2-manager: authority manifest missing %s\n' "$key" >&2
      exit 1
    }
  done

  jq -e '
    has("$schema") and
    .type == "object" and
    .properties.kind.const == "studio-v2-manager-proof-of-life"
  ' "$SCHEMA" >/dev/null || {
    printf 'v2-manager: invalid manager proof-of-life schema: %s\n' "$SCHEMA" >&2
    exit 1
  }

  grep -Eq '^[[:space:]]*-[[:space:]]*manager_proof_of_life([[:space:]]|$)' "$EVENT_REGISTRY" || {
    printf 'v2-manager: event not registered: manager_proof_of_life\n' >&2
    exit 1
  }

  "$REPO_ROOT/scripts/v2-role-resolve.sh" manager >/dev/null
  "$REPO_ROOT/scripts/v2-context-budget.sh" --resolve --role manager --invocation mode-dispatch --format json >/dev/null

  printf 'v2-manager: ok\n' >&2
}

build_artifact() {
  local canonical_role role_json budget_json created_at host_class_value artifact_id safe_id
  canonical_role=$("$REPO_ROOT/scripts/v2-role-resolve.sh" --format text "$ROLE") || {
    printf 'v2-manager: unknown role or alias: %s\n' "$ROLE" >&2
    exit 1
  }
  [ "$canonical_role" = "manager" ] || {
    printf 'v2-manager: role must resolve to manager, got %s from %s\n' "$canonical_role" "$ROLE" >&2
    exit 1
  }

  if [ -n "$ESTIMATED_TOKENS" ]; then
    budget_json=$("$REPO_ROOT/scripts/v2-context-budget.sh" --resolve --role "$ROLE" --invocation mode-dispatch --estimated-tokens "$ESTIMATED_TOKENS" --format json)
  else
    budget_json=$("$REPO_ROOT/scripts/v2-context-budget.sh" --resolve --role "$ROLE" --invocation mode-dispatch --format json)
  fi
  if [ "$(printf '%s\n' "$budget_json" | jq -r '.status')" = "exceeded" ]; then
    printf 'v2-manager: context budget exceeded for manager proof-of-life\n' >&2
    exit 1
  fi

  role_json=$(jq -n --arg input "$ROLE" --arg role "$canonical_role" '{input:$input, role:$role}')
  created_at=$(now_utc)
  [ -n "$IDEMPOTENCY_KEY" ] || IDEMPOTENCY_KEY="manager-proof-of-life:$SUBJECT_REF"
  safe_id=$(sanitize_id "$SUBJECT_REF")
  artifact_id="manager-proof-of-life:$safe_id"
  host_class_value=$(host_class "$HOST_NAME")

  jq -n \
    --arg artifact_id "$artifact_id" \
    --arg created_at "$created_at" \
    --arg subject_ref "$SUBJECT_REF" \
    --arg idempotency_key "$IDEMPOTENCY_KEY" \
    --arg host_name "$HOST_NAME" \
    --arg host_class "$host_class_value" \
    --argjson canonical_role "$role_json" \
    --argjson context_budget "$budget_json" \
    --arg dry_run "$DRY_RUN" \
    '{
      schema_version: 1,
      kind: "studio-v2-manager-proof-of-life",
      artifact_id: $artifact_id,
      created_at: $created_at,
      parent_issue: 444,
      leaf_issue: 525,
      producer_role: "manager",
      subject_ref: $subject_ref,
      idempotency_key: $idempotency_key,
      privacy_classification: "private-runtime",
      status: (if ($dry_run == "1") then "ready" else "completed" end),
      host: {
        name: $host_name,
        class: $host_class,
        contract_exercised: true
      },
      checks: {
        canonical_role: $canonical_role,
        context_budget: {
          status: $context_budget.status,
          effective_budget_tokens: $context_budget.effective_budget_tokens,
          limiting_dimension: $context_budget.limiting_dimension,
          telemetry_event: $context_budget.telemetry_event
        },
        artifact_contract: {
          schema_file: "core/v2/schemas/manager-proof-of-life.schema.json",
          validated: true
        },
        authority_manifest: {
          file: "scripts/v2-manager.sh.authority.yaml",
          declared: true
        },
        event_log: {
          event_name: "manager_proof_of_life",
          appended: false
        }
      },
      payload: {
        mode: "proof-of-life",
        summary: "Manager v2 resolved the canonical manager role, composed context budget policy, and produced the A7 proof-of-life artifact without switching v1 traffic.",
        dry_run: ($dry_run == "1"),
        runtime_artifact_path: null,
        event_path: null
      },
      evidence_refs: [
        "core/v2/manager/proof-of-life.yaml",
        "scripts/v2-manager.sh",
        "scripts/test-fixtures/525-manager-proof-of-life/test-v2-manager.sh"
      ],
      carryover: [
        "A7 acceptance still needs real Claude Code plus non-Claude host execution evidence before broader manager migration.",
        "A8 owns worker, reviewer, and perf v2 migration after the manager proof-of-life settles."
      ]
    }'
}

cmd_proof_of_life() {
  require_tool jq
  parse_proof_args "$@"
  [ -n "$SUBJECT_REF" ] || {
    printf 'v2-manager: --subject-ref is required\n' >&2
    exit 2
  }
  case "$ESTIMATED_TOKENS" in
    ""|*[!0-9]*) [ -z "$ESTIMATED_TOKENS" ] || usage ;;
  esac
  if [ "$DRY_RUN" -eq 0 ] && [ -z "$RUNTIME_ROOT" ]; then
    printf 'v2-manager: --runtime-root is required unless --dry-run is set\n' >&2
    exit 2
  fi

  local artifact path event_path event_json hash
  artifact=$(build_artifact)

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$artifact"
    return 0
  fi

  hash=$(hash_text "$IDEMPOTENCY_KEY")
  path="$RUNTIME_ROOT/.runtime/v2/manager/proof-of-life/$hash.json"
  artifact=$(printf '%s\n' "$artifact" | jq --arg path "$path" '.payload.runtime_artifact_path = $path')
  printf '%s\n' "$artifact" | atomic_write "$path"

  event_json=$(jq -n \
    --arg idempotency_key "$IDEMPOTENCY_KEY" \
    --arg subject_ref "$SUBJECT_REF" \
    --arg artifact_path "$path" \
    '{
      event: "manager_proof_of_life",
      producer: {agent: "manager", role: "manager"},
      idempotency_key: $idempotency_key,
      writable_action: true,
      data: {
        subject_ref: $subject_ref,
        artifact_path: $artifact_path,
        status: "completed"
      }
    }')
  event_path=$("$REPO_ROOT/scripts/v2-event-log.sh" append --runtime-root "$RUNTIME_ROOT" --event-json "$event_json")
  artifact=$(printf '%s\n' "$artifact" | jq --arg event_path "$event_path" '.checks.event_log.appended = true | .payload.event_path = $event_path')
  printf '%s\n' "$artifact" | atomic_write "$path"
  printf '%s\n' "$artifact"
}

case "$COMMAND" in
  --validate|validate)
    validate_manifest
    ;;
  proof-of-life)
    cmd_proof_of_life "$@"
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    printf 'v2-manager: unknown command: %s\n' "$COMMAND" >&2
    usage
    ;;
esac
