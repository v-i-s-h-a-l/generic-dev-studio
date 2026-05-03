#!/usr/bin/env bash

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
RUN="$ROOT/scripts/v2-manager.sh"
SCHEMA="$ROOT/core/v2/schemas/manager-proof-of-life.schema.json"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -x "$RUN" ] || fail "scripts/v2-manager.sh is not executable"

"$RUN" --validate >/tmp/v2-manager-validate.out 2>/tmp/v2-manager-validate.err
grep -q 'v2-manager: ok' /tmp/v2-manager-validate.err || {
  cat /tmp/v2-manager-validate.err >&2
  fail "validate did not report ok"
}

dry_json=$("$RUN" proof-of-life --subject-ref issue:525 --host codex --dry-run)
printf '%s\n' "$dry_json" | jq -e '
  .kind == "studio-v2-manager-proof-of-life"
  and .parent_issue == 444
  and .leaf_issue == 525
  and .producer_role == "manager"
  and .subject_ref == "issue:525"
  and .idempotency_key == "manager-proof-of-life:issue:525"
  and .host.name == "codex"
  and .host.class == "non-claude"
  and .checks.canonical_role.role == "manager"
  and .checks.context_budget.status == "unmeasured"
  and .checks.artifact_contract.validated == true
  and .checks.authority_manifest.declared == true
  and .checks.event_log.appended == false
  and .payload.dry_run == true
  and .payload.runtime_artifact_path == null
  and .payload.event_path == null
' >/dev/null || {
  printf '%s\n' "$dry_json" >&2
  fail "dry-run artifact missing expected manager fields"
}

dry_file=/tmp/v2-manager-dry-run.json
printf '%s\n' "$dry_json" > "$dry_file"
check-jsonschema --schemafile "$SCHEMA" "$dry_file" >/tmp/v2-manager-schema.out 2>/tmp/v2-manager-schema.err || {
  cat /tmp/v2-manager-schema.err >&2
  fail "dry-run artifact did not validate against schema"
}

alias_json=$("$RUN" proof-of-life --role chanakya --subject-ref issue:525 --host claude-code --dry-run)
printf '%s\n' "$alias_json" | jq -e '
  .checks.canonical_role.input == "chanakya"
  and .checks.canonical_role.role == "manager"
  and .host.class == "claude-code"
' >/dev/null || {
  printf '%s\n' "$alias_json" >&2
  fail "chanakya alias did not resolve to manager"
}

if "$RUN" proof-of-life --role reviewer --subject-ref issue:525 --dry-run >/tmp/v2-manager-bad-role.out 2>/tmp/v2-manager-bad-role.err; then
  fail "non-manager role should fail"
fi
grep -Eq 'role must resolve to manager|unknown role or alias' /tmp/v2-manager-bad-role.err || {
  cat /tmp/v2-manager-bad-role.err >&2
  fail "bad role error was not actionable"
}

bad_file=/tmp/v2-manager-bad-artifact.json
printf '%s\n' "$dry_json" | jq 'del(.subject_ref)' > "$bad_file"
if check-jsonschema --schemafile "$SCHEMA" "$bad_file" >/tmp/v2-manager-bad-schema.out 2>/tmp/v2-manager-bad-schema.err; then
  fail "schema should reject artifact missing subject_ref"
fi

runtime_root=$(mktemp -d "/tmp/v2-manager-runtime.XXXXXX")
write_json=$("$RUN" proof-of-life --subject-ref issue:525 --host codex --runtime-root "$runtime_root")
artifact_path=$(printf '%s\n' "$write_json" | jq -r '.payload.runtime_artifact_path')
event_path=$(printf '%s\n' "$write_json" | jq -r '.payload.event_path')

[ -f "$artifact_path" ] || fail "runtime artifact was not written"
[ -f "$event_path" ] || fail "event shard was not written"
printf '%s\n' "$write_json" | jq -e '
  .status == "completed"
  and .checks.event_log.appended == true
  and .payload.dry_run == false
  and (.payload.runtime_artifact_path | type == "string")
  and (.payload.event_path | type == "string")
' >/dev/null || {
  printf '%s\n' "$write_json" >&2
  fail "write artifact missing expected runtime fields"
}
check-jsonschema --schemafile "$SCHEMA" "$artifact_path" >/tmp/v2-manager-write-schema.out 2>/tmp/v2-manager-write-schema.err || {
  cat /tmp/v2-manager-write-schema.err >&2
  fail "written artifact did not validate"
}
grep -q '"event":"manager_proof_of_life"' "$event_path" || fail "manager event was not appended"

printf 'PASS: v2 manager proof-of-life\n'
