#!/usr/bin/env bash
# lint-v2-enforcement.sh - A0.6 SPEC-derived gate for Studio v2 substrate files.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

MODE="full"
case "${1:-}" in
  --staged) MODE="staged" ;;
  --full|"") MODE="full" ;;
  *) printf 'usage: lint-v2-enforcement.sh [--staged|--full]\n' >&2; exit 2 ;;
esac

ERRORS=0
ERROR_LINES=""

emit_error() {
  ERROR_LINES="${ERROR_LINES}${1}"$'\n'
  ERRORS=$((ERRORS + 1))
}

rel_for() {
  case "$1" in
    "$REPO_ROOT"/*) printf '%s\n' "${1#"$REPO_ROOT/"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

staged_paths() {
  git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true
}

full_paths() {
  (
    cd "$REPO_ROOT" || exit 1
    find core/v2 profiles -type f 2>/dev/null || true
    [ -f .githooks/pre-commit ] && printf '%s\n' .githooks/pre-commit
    [ -f scripts/lint-v2-enforcement.sh ] && printf '%s\n' scripts/lint-v2-enforcement.sh
  )
}

paths_to_check() {
  if [ "$MODE" = "staged" ]; then
    staged_paths
  else
    full_paths
  fi
}

has_v2_surface() {
  if [ -d "$REPO_ROOT/core/v2" ] || [ -d "$REPO_ROOT/profiles" ]; then
    return 0
  fi
  paths_to_check | grep -Eq '^(core/v2/|profiles/|scripts/lint-v2-|\.githooks/pre-commit$)' 2>/dev/null
}

staged_has_v2_runtime_surface() {
  [ "$MODE" = "staged" ] || return 1
  staged_paths | grep -Eq '^(core/v2/|profiles/)' 2>/dev/null
}

require_exact_line() {
  local rel="$1" needle="$2" code="$3" reason="$4"
  [ -f "$REPO_ROOT/$rel" ] || return 0
  grep -Fxq "$needle" "$REPO_ROOT/$rel" || emit_error "$code:$rel:missing=$needle | $reason"
}

require_yaml_key() {
  local rel="$1" key="$2" code="$3" reason="$4"
  [ -f "$REPO_ROOT/$rel" ] || return 0
  if command -v yq >/dev/null 2>&1; then
    yq -e "has(\"$key\")" "$REPO_ROOT/$rel" >/dev/null 2>&1 || emit_error "$code:$rel:missing=$key | $reason"
  else
    grep -Eq "^${key}:" "$REPO_ROOT/$rel" || emit_error "$code:$rel:missing=$key | $reason"
  fi
}

yaml_key_exists() {
  local rel="$1" key="$2"
  [ -f "$REPO_ROOT/$rel" ] || return 1
  if command -v yq >/dev/null 2>&1; then
    yq -e "has(\"$key\")" "$REPO_ROOT/$rel" >/dev/null 2>&1
  else
    grep -Eq "^${key}:" "$REPO_ROOT/$rel"
  fi
}

check_spec_contract() {
  local spec="core/v2/SPEC.md"
  if [ ! -f "$REPO_ROOT/$spec" ]; then
    if [ -d "$REPO_ROOT/core/v2" ] || [ -d "$REPO_ROOT/profiles" ] || staged_has_v2_runtime_surface; then
      emit_error "E_V2_SPEC_MISSING:$spec | A0.6 enforcement requires the A0.5 signed-off SPEC"
    fi
    return 0
  fi

  require_exact_line "$spec" '<!-- v2-bootstrap:a0.5-sign-off:complete -->' \
    E_V2_SPEC_SIGNOFF 'restore the A0.5 sign-off marker before enforcing post-bootstrap substrate rules'

  local anchor
  for anchor in \
    '<!-- v2-spec:source-inputs -->' \
    '<!-- v2-spec:principles -->' \
    '<!-- v2-spec:host-floor -->' \
    '<!-- v2-spec:artifact-root -->' \
    '<!-- v2-spec:event-log -->' \
    '<!-- v2-spec:auth-permissions -->' \
    '<!-- v2-spec:roles-handoffs -->' \
    '<!-- v2-spec:project-profiles -->' \
    '<!-- v2-spec:context-budget -->' \
    '<!-- v2-spec:testing-release -->' \
    '<!-- v2-spec:bootstrap-gate -->' \
    '<!-- v2-spec:carryover -->'
  do
    require_exact_line "$spec" "$anchor" E_V2_SPEC_ANCHOR 'restore the required SPEC anchor'
  done
}

check_hook_wiring() {
  local hook=".githooks/pre-commit"
  [ -f "$REPO_ROOT/$hook" ] || return 0
  if ! grep -q 'lint-v2-enforcement.sh" --staged\|lint-v2-enforcement.sh --staged' "$REPO_ROOT/$hook"; then
    emit_error "E_V2_HOOK:$hook | delegate to scripts/lint-v2-enforcement.sh --staged"
  fi
}

check_json_schema_files() {
  local f rel
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel=$(rel_for "$f")
    if ! jq -e 'has("$schema") and (has("type") or has("oneOf") or has("anyOf"))' "$f" >/dev/null 2>&1; then
      emit_error "E_V2_SCHEMA:$rel | JSON schemas need \$schema plus type/oneOf/anyOf"
    fi
  done < <(find "$REPO_ROOT/core/v2" "$REPO_ROOT/profiles" -type f -name '*.schema.json' 2>/dev/null)
}

check_handoff_contracts() {
  local f rel key
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel=$(rel_for "$f")
    for key in schema_version artifact_kind artifact_id producer_role consumer_role subject_ref idempotency_key payload evidence_refs privacy_classification status; do
      require_yaml_key "$rel" "$key" E_V2_HANDOFF_FIELD 'handoff artifacts must carry the SPEC minimum envelope'
    done
  done < <(find "$REPO_ROOT/core/v2/handoffs" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null)
}

check_role_contracts() {
  local f rel key
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel=$(rel_for "$f")
    for key in purpose inputs outputs reads writes idempotency_key decision_rights escalation_triggers failure_semantics verification_floor; do
      require_yaml_key "$rel" "$key" E_V2_ROLE_FIELD 'role contracts must declare the SPEC minimum fields'
    done
  done < <(find "$REPO_ROOT/core/v2/roles" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null)
}

check_authority_manifests() {
  local f rel authority key
  find "$REPO_ROOT/core/v2/actions" "$REPO_ROOT/profiles" -type f 2>/dev/null | while IFS= read -r f; do
    rel=$(rel_for "$f")
    case "$rel" in
      *.authority.yaml|*.authority.yml|*.md|*.json|*.yaml|*.yml) continue ;;
    esac
    [ -x "$f" ] || head -n 1 "$f" 2>/dev/null | grep -q '^#!' || continue
    authority="${rel}.authority.yaml"
    if [ ! -f "$REPO_ROOT/$authority" ]; then
      printf 'E_V2_AUTHORITY:%s | mutating/executable v2 actions need a sidecar .authority.yaml manifest\n' "$rel"
      continue
    fi
    for key in action role filesystem commands secret_scopes mutation_scopes interactive headless_safe failure_classes override; do
      if ! yaml_key_exists "$authority" "$key"; then
        printf 'E_V2_AUTHORITY_FIELD:%s:missing=%s | authority manifests must declare permission and failure boundaries\n' "$authority" "$key"
      fi
    done
  done
}

check_event_fixtures() {
  local f rel line_no line bytes event registry
  registry="$REPO_ROOT/core/v2/events/registry.yaml"
  find "$REPO_ROOT/core/v2/events" -type f -name '*.jsonl' 2>/dev/null | while IFS= read -r f; do
    rel=$(rel_for "$f")
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      bytes=$(printf '%s' "$line" | wc -c | tr -d ' ')
      if [ "$bytes" -gt 4096 ]; then
        printf 'E_V2_EVENT_BOUNDS:%s:%s | event payload lines must stay <=4096 bytes\n' "$rel" "$line_no"
      fi
      if ! printf '%s\n' "$line" | jq -e 'type == "object" and (.event | type == "string" and length > 0)' >/dev/null 2>&1; then
        printf 'E_V2_EVENT_JSON:%s:%s | event lines must be bounded JSON objects with event names\n' "$rel" "$line_no"
        continue
      fi
      event=$(printf '%s\n' "$line" | jq -r '.event')
      if [ -f "$registry" ] && ! grep -Eq "^[[:space:]]*-[[:space:]]*$event([[:space:]]|$)" "$registry"; then
        printf 'E_V2_EVENT_REGISTRY:%s:%s:%s | event name must be registered in core/v2/events/registry.yaml\n' "$rel" "$line_no" "$event"
      fi
      if printf '%s\n' "$line" | jq -e '.writable_action == true and ((.idempotency_key // "") == "")' >/dev/null 2>&1; then
        printf 'E_V2_EVENT_IDEMPOTENCY:%s:%s | writable events require idempotency_key\n' "$rel" "$line_no"
      fi
    done < "$f"
  done
}

check_subscriber_checkpoints() {
  local f rel key
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel=$(rel_for "$f")
    for key in subscriber shard next_byte_offset updated_at; do
      require_yaml_key "$rel" "$key" E_V2_CHECKPOINT_FIELD 'subscriber checkpoints must carry replay coordinates'
    done
  done < <(find "$REPO_ROOT/core/v2/subscribers" -type f \( -name '*.checkpoint.yaml' -o -name '*.checkpoint.yml' \) 2>/dev/null)
}

check_router_constraints() {
  local router_lint_out router_lint_rc
  [ -x "$SCRIPT_DIR/v2-router-lint.sh" ] || {
    printf 'E_V2_ROUTER_LINT:scripts/v2-router-lint.sh | v2 router enforcement must delegate to the A2a router linter\n'
    return 0
  }

  router_lint_out=$("$SCRIPT_DIR/v2-router-lint.sh" "--$MODE" 2>&1)
  router_lint_rc=$?
  if [ "$router_lint_rc" -ne 0 ]; then
    printf '%s\n' "$router_lint_out"
  fi
}

check_profile_boundaries() {
  local d profile
  find "$REPO_ROOT/profiles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
    profile="${d#"$REPO_ROOT/"}/profile.yaml"
    if [ ! -f "$REPO_ROOT/$profile" ]; then
      printf 'E_V2_PROFILE:%s | each v2 project profile needs profile.yaml for command/rule boundaries\n' "${d#"$REPO_ROOT/"}"
      continue
    fi
    if ! yaml_key_exists "$profile" operations; then
      printf 'E_V2_PROFILE_FIELD:%s:missing=operations | profiles must map abstract operations to project commands\n' "$profile"
    fi
    if ! yaml_key_exists "$profile" rules; then
      printf 'E_V2_PROFILE_FIELD:%s:missing=rules | profiles must declare profile-local rules\n' "$profile"
    fi
  done
}

check_docs_guidance() {
  local f rel
  find "$REPO_ROOT/core/v2/docs" -type f -name '*.md' 2>/dev/null | while IFS= read -r f; do
    rel=$(rel_for "$f")
    if ! grep -Eiq 'automation mode|headless|unattended|operator override' "$f"; then
      printf 'E_V2_DOCS_AUTOMATION:%s | v2 docs must make automation/headless/operator-override guidance explicit\n' "$rel"
    fi
  done
}

check_context_budget_manifest() {
  local manifest="core/v2/context-budget/manifest.json"
  local schema="core/v2/schemas/context-budget.schema.json"
  local resolver="scripts/v2-context-budget.sh"

  [ -f "$REPO_ROOT/$manifest" ] || return 0

  [ -f "$REPO_ROOT/$schema" ] || {
    emit_error "E_V2_CONTEXT_BUDGET_SCHEMA:$schema | context-budget manifests need a schema"
    return 0
  }
  [ -x "$REPO_ROOT/$resolver" ] || {
    emit_error "E_V2_CONTEXT_BUDGET_RESOLVER:$resolver | context-budget manifests need an executable resolver"
    return 0
  }

  local out rc
  out=$("$REPO_ROOT/$resolver" --manifest "$REPO_ROOT/$manifest" --validate 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    emit_error "E_V2_CONTEXT_BUDGET:$manifest | resolver validation failed: $out"
  fi
}

collect_subprocess_errors() {
  while IFS= read -r line; do
    [ -n "$line" ] && emit_error "$line"
  done
}

has_v2_surface || {
  printf 'lint-v2-enforcement: ok (%s, no v2 substrate surface)\n' "$MODE" >&2
  exit 0
}

check_spec_contract
check_hook_wiring

if command -v jq >/dev/null 2>&1; then
  check_json_schema_files
else
  emit_error "E_V2_TOOLING:jq | v2 enforcement requires jq"
fi

check_handoff_contracts
check_role_contracts
collect_subprocess_errors < <(check_authority_manifests)
collect_subprocess_errors < <(check_event_fixtures)
check_subscriber_checkpoints
collect_subprocess_errors < <(check_router_constraints)
collect_subprocess_errors < <(check_profile_boundaries)
collect_subprocess_errors < <(check_docs_guidance)
check_context_budget_manifest

if [ -x "$SCRIPT_DIR/lint-field-review-surfaces.sh" ] && { [ -d "$REPO_ROOT/core/v2" ] || [ -d "$REPO_ROOT/profiles" ]; }; then
  field_review_out=$("$SCRIPT_DIR/lint-field-review-surfaces.sh" "$REPO_ROOT/core/v2" "$REPO_ROOT/profiles" 2>&1)
  field_review_rc=$?
  if [ "$field_review_rc" -ne 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && emit_error "$line"
    done <<EOF
$field_review_out
EOF
  fi
fi

if [ "$ERRORS" -gt 0 ]; then
  printf 'lint-v2-enforcement: %d errors (%s)\n' "$ERRORS" "$MODE" >&2
  printf '%s' "$ERROR_LINES" >&2
  exit 1
fi

printf 'lint-v2-enforcement: ok (%s)\n' "$MODE" >&2
exit 0
