#!/usr/bin/env bash
# Resolve Studio v2 skills from a YAML ruleset and invocation context JSON.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
RULES="$REPO_ROOT/core/v2/skills/routing-rules.yaml"
SCHEMA="$REPO_ROOT/core/v2/schemas/skill-routing-rules.schema.json"
ROLE_RESOLVE="$REPO_ROOT/scripts/v2-role-resolve.sh"
FORMAT="json"
CONTEXT=""

usage() {
  cat >&2 <<'USAGE'
usage: scripts/v2-skill-route.sh --context <context.json> [--rules <rules.yaml>] [--format json|names]
       scripts/v2-skill-route.sh --context -              [--rules <rules.yaml>] [--format json|names]
       scripts/v2-skill-route.sh --validate-only          [--rules <rules.yaml>]

Context JSON fields:
  role or agent          Studio v2 role name or alias, resolved via core/v2/registry/roles.json
  invocation_phase       Optional phase such as pre-edit, post-diff, review, plan
  task_type              Optional task type such as feature, bugfix, test-unit
  stack                  Optional stack/profile label such as swift or ios
  paths                  Optional array of changed or anticipated paths
  prompt                 Optional text from the brief, plan, or diff summary
USAGE
}

require_tools() {
  command -v jq >/dev/null 2>&1 || {
    printf 'v2-skill-route: jq is required\n' >&2
    exit 3
  }
  command -v yq >/dev/null 2>&1 || {
    printf 'v2-skill-route: yq is required\n' >&2
    exit 3
  }
}

rules_to_json() {
  local src="$1" dest="$2"
  [ -r "$src" ] || {
    printf 'v2-skill-route: rules not readable: %s\n' "$src" >&2
    exit 3
  }
  if ! yq -o=json '.' "$src" >"$dest"; then
    printf 'v2-skill-route: rules are not valid YAML: %s\n' "$src" >&2
    exit 3
  fi
}

validate_rules() {
  local rules_json="$1"
  if command -v check-jsonschema >/dev/null 2>&1; then
    check-jsonschema --schemafile "$SCHEMA" "$rules_json" >/dev/null || {
      printf 'v2-skill-route: rules failed schema validation: %s\n' "$RULES" >&2
      exit 3
    }
  else
    jq -e '
      .schema_version == 1 and
      .kind == "studio-v2-skill-routing-rules" and
      .parent_issue == 444 and
      .leaf_issue == 519 and
      (.rules | type == "array") and
      (.rules | length > 0)
    ' "$rules_json" >/dev/null || {
      printf 'v2-skill-route: invalid rules envelope: %s\n' "$RULES" >&2
      exit 3
    }
  fi

  jq -e '
    ([.rules[].id] | unique | length) == (.rules | length)
  ' "$rules_json" >/dev/null || {
    printf 'v2-skill-route: duplicate rule id in %s\n' "$RULES" >&2
    exit 3
  }
}

read_context() {
  local source="$1" dest="$2"
  if [ "$source" = "-" ]; then
    cat >"$dest"
  else
    [ -r "$source" ] || {
      printf 'v2-skill-route: context not readable: %s\n' "$source" >&2
      exit 3
    }
    cp "$source" "$dest"
  fi
  jq -e 'type == "object"' "$dest" >/dev/null || {
    printf 'v2-skill-route: context must be a JSON object\n' >&2
    exit 3
  }
}

normalize_context() {
  local context_json="$1" normalized_json="$2"
  local role_input canonical_role

  role_input=$(jq -r '.role // .agent // empty' "$context_json")
  [ -n "$role_input" ] || {
    printf 'v2-skill-route: context requires role or agent\n' >&2
    exit 2
  }

  canonical_role=$("$ROLE_RESOLVE" "$role_input") || {
    printf 'v2-skill-route: context role/agent is not a known Studio v2 role: %s\n' "$role_input" >&2
    exit 1
  }

  jq --arg role "$canonical_role" '
    .role = $role
    | .agent = (.agent // null)
    | .invocation_phase = (.invocation_phase // .phase // "")
    | .task_type = (.task_type // "")
    | .stack = (.stack // .profile // "")
    | .paths = (if (.paths // []) | type == "array" then (.paths // []) else [(.paths | tostring)] end)
    | .prompt = (.prompt // .summary // .title // "")
  ' "$context_json" >"$normalized_json"
}

resolve_rules() {
  local rules_json="$1" context_json="$2"
  jq -n --slurpfile rules "$rules_json" --slurpfile contexts "$context_json" '
    def arr($x):
      if $x == null then []
      elif ($x | type) == "array" then $x
      else [$x]
      end;

    def list_allows($allowed; $value):
      (arr($allowed) | length) == 0 or ((arr($allowed) | index($value)) != null);

    def text_matches($regexes; $text):
      (arr($regexes) | length) == 0
      or ([arr($regexes)[] as $re | select(($text // "") | test($re; "i"))] | length > 0);

    def path_matches($regexes; $paths):
      (arr($regexes) | length) == 0
      or ([arr($regexes)[] as $re | arr($paths)[] | select(test($re))] | length > 0);

    def rule_matches($rule; $context):
      ($rule.when // {}) as $w
      | list_allows($w.roles; $context.role)
        and list_allows($w.phases; $context.invocation_phase)
        and list_allows($w.task_types; $context.task_type)
        and list_allows($w.stacks; $context.stack)
        and path_matches($w.path_regexes; $context.paths)
        and text_matches($w.prompt_regexes; $context.prompt);

    ($rules[0]) as $ruleset
    | ($contexts[0]) as $context
    | [
        $ruleset.rules[]
        | select(rule_matches(.; $context))
        | {
            rule_id: .id,
            priority: .priority,
            skills: .skills,
            finding_category: (.finding_category // null),
            source: .source,
            description: .description
          }
      ]
      | sort_by([- .priority, .rule_id]) as $matches
      | {
          schema_version: 1,
          kind: "studio-v2-skill-routing-result",
          parent_issue: 444,
          leaf_issue: 519,
          ruleset: {
            path: "'"${RULES#"$REPO_ROOT/"}"'",
            schema_version: $ruleset.schema_version,
            kind: $ruleset.kind
          },
          context: {
            role: $context.role,
            agent: $context.agent,
            invocation_phase: $context.invocation_phase,
            task_type: $context.task_type,
            stack: $context.stack,
            paths: $context.paths
          },
          match_count: ($matches | length),
          matches: $matches,
          skills: ([$matches[].skills[]] | unique)
        }
  '
}

VALIDATE_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --rules)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      RULES="$2"
      shift 2
      ;;
    --context)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      CONTEXT="$2"
      shift 2
      ;;
    --format)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      FORMAT="$2"
      case "$FORMAT" in
        json|names) ;;
        *) usage; exit 2 ;;
      esac
      shift 2
      ;;
    --validate-only)
      VALIDATE_ONLY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      usage
      exit 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

require_tools

TMPDIR=$(mktemp -d -t v2-skill-route.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

RULES_JSON="$TMPDIR/rules.json"
rules_to_json "$RULES" "$RULES_JSON"
validate_rules "$RULES_JSON"

if [ "$VALIDATE_ONLY" -eq 1 ]; then
  printf 'PASS: skill routing rules valid: %s\n' "$RULES"
  exit 0
fi

[ -n "$CONTEXT" ] || { usage; exit 2; }

CONTEXT_JSON="$TMPDIR/context.json"
NORMALIZED_CONTEXT_JSON="$TMPDIR/context.normalized.json"
RESULT_JSON="$TMPDIR/result.json"

read_context "$CONTEXT" "$CONTEXT_JSON"
normalize_context "$CONTEXT_JSON" "$NORMALIZED_CONTEXT_JSON"
resolve_rules "$RULES_JSON" "$NORMALIZED_CONTEXT_JSON" >"$RESULT_JSON"

case "$FORMAT" in
  json)
    cat "$RESULT_JSON"
    ;;
  names)
    jq -r '.skills[]?' "$RESULT_JSON"
    ;;
esac
