#!/usr/bin/env bash
# Verifies A0.6 v2 enforcement gates on synthetic substrate artifacts.

set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t v2-enforcement.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

make_repo() {
  repo="$1"
  mkdir -p "$repo/scripts" "$repo/core/v2/actions" "$repo/core/v2/docs" \
    "$repo/core/v2/events" "$repo/core/v2/handoffs" "$repo/core/v2/roles" \
    "$repo/core/v2/routers" "$repo/core/v2/schemas" "$repo/core/v2/subscribers" \
    "$repo/profiles/ios/commands" "$repo/.githooks"
  cp "$ROOT/scripts/lint-v2-enforcement.sh" "$repo/scripts/lint-v2-enforcement.sh"
  cp "$ROOT/scripts/v2-router-lint.sh" "$repo/scripts/v2-router-lint.sh"
  cp "$ROOT/scripts/lint-field-review-surfaces.sh" "$repo/scripts/lint-field-review-surfaces.sh"
  cat > "$repo/.githooks/pre-commit" <<'SH'
#!/usr/bin/env bash
scripts/lint-v2-enforcement.sh --staged
SH
  cat > "$repo/core/v2/SPEC.md" <<'MD'
# Studio v2 Substrate SPEC
<!-- v2-bootstrap:a0.5-sign-off:complete -->
<!-- v2-spec:source-inputs -->
<!-- v2-spec:principles -->
<!-- v2-spec:host-floor -->
<!-- v2-spec:artifact-root -->
<!-- v2-spec:event-log -->
<!-- v2-spec:auth-permissions -->
<!-- v2-spec:roles-handoffs -->
<!-- v2-spec:project-profiles -->
<!-- v2-spec:context-budget -->
<!-- v2-spec:testing-release -->
<!-- v2-spec:bootstrap-gate -->
<!-- v2-spec:carryover -->
MD
  cat > "$repo/core/v2/schemas/handoff.schema.json" <<'JSON'
{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}
JSON
  cat > "$repo/core/v2/handoffs/worker.yaml" <<'YAML'
schema_version: 1
artifact_kind: worker-contract
artifact_id: worker-1
producer_role: planner
consumer_role: worker
subject_ref: issue-1
idempotency_key: issue-1-worker
payload: {}
evidence_refs: []
privacy_classification: private-runtime
status: ready
YAML
  cat > "$repo/core/v2/roles/worker.yaml" <<'YAML'
purpose: implement scoped work
inputs: []
outputs: []
reads: []
writes: []
idempotency_key: worker
decision_rights: []
escalation_triggers: []
failure_semantics: []
verification_floor: []
YAML
  cat > "$repo/core/v2/actions/mutate" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/core/v2/actions/mutate"
  cat > "$repo/core/v2/actions/mutate.authority.yaml" <<'YAML'
action: mutate
role: helper
filesystem:
  reads: []
  writes: []
commands: []
secret_scopes: []
mutation_scopes: []
interactive: false
headless_safe: true
failure_classes: []
override: null
YAML
  cat > "$repo/core/v2/events/registry.yaml" <<'YAML'
events:
  - v2_event
YAML
  printf '{"event":"v2_event","writable_action":true,"idempotency_key":"evt-1"}\n' > "$repo/core/v2/events/sample.jsonl"
  cat > "$repo/core/v2/subscribers/reader.checkpoint.yaml" <<'YAML'
subscriber: reader
shard: "2026-05-03"
next_byte_offset: 0
updated_at: "2026-05-03T00:00:00Z"
YAML
  cat > "$repo/core/v2/routers/router.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  run) exec core/v2/actions/mutate ;;
  *) exit 2 ;;
esac
SH
  cat > "$repo/core/v2/docs/operator.md" <<'MD'
Automation mode is the default; operator override remains explicit.
MD
  cat > "$repo/profiles/ios/profile.yaml" <<'YAML'
operations: {}
rules: []
YAML
  cat > "$repo/profiles/ios/commands/build" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/profiles/ios/commands/build"
  cat > "$repo/profiles/ios/commands/build.authority.yaml" <<'YAML'
action: build
role: helper
filesystem:
  reads: []
  writes: []
commands: []
secret_scopes: []
mutation_scopes: []
interactive: false
headless_safe: true
failure_classes: []
override: null
YAML
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
}

GOOD="$TMPROOT/good"
make_repo "$GOOD"
(cd "$GOOD" && scripts/lint-v2-enforcement.sh --full >"$TMPROOT/good.out" 2>"$TMPROOT/good.err")

BAD="$TMPROOT/bad"
make_repo "$BAD"
rm "$BAD/core/v2/actions/mutate.authority.yaml"
cat > "$BAD/core/v2/roles/worker.yaml" <<'YAML'
purpose: incomplete
YAML
printf '{"event":"unregistered","writable_action":true}\n' > "$BAD/core/v2/events/sample.jsonl"
cat > "$BAD/core/v2/routers/router.sh" <<'SH'
#!/usr/bin/env bash
git push origin feature/v2-router-work
SH

if (cd "$BAD" && scripts/lint-v2-enforcement.sh --full >"$TMPROOT/bad.out" 2>"$TMPROOT/bad.err"); then
  printf 'FAIL: bad v2 substrate passed enforcement\n' >&2
  exit 1
fi

grep -q 'E_V2_AUTHORITY:core/v2/actions/mutate' "$TMPROOT/bad.err"
grep -q 'E_V2_ROLE_FIELD:core/v2/roles/worker.yaml:missing=inputs' "$TMPROOT/bad.err"
grep -q 'E_V2_EVENT_REGISTRY:core/v2/events/sample.jsonl:1:unregistered' "$TMPROOT/bad.err"
grep -q 'E_V2_EVENT_IDEMPOTENCY:core/v2/events/sample.jsonl:1' "$TMPROOT/bad.err"
grep -q 'E_V2_ROUTER_LOGIC:core/v2/routers/router.sh' "$TMPROOT/bad.err"

printf 'PASS: v2 enforcement gate\n'
