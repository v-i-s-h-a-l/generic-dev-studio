#!/usr/bin/env bash
# scaffold-skill.sh <name> [--dir skills/owned] [--type skill]
#
# Emits a Skill-Authoring-Standard-conformant skeleton:
#   <dir>/<name>/SKILL.md         seeded from skills/owned/exemplar
#   <dir>/<name>/routing.yaml     templated invocation manifest
#   <dir>/<name>/portability.yaml claude-code + codex by default
#
# The output passes scripts/lint-skill-prose.sh on first try. Any drift is a
# regression in either the exemplar (the seed) or the linter (the gate) —
# treat both as test fixtures for the standard itself.
#
# Examples:
#   scripts/scaffold-skill.sh foo                          # → skills/owned/foo/
#   scripts/scaffold-skill.sh foo --dir achilles/modes     # → achilles/modes/foo/
#   scripts/scaffold-skill.sh foo --type mode-pack         # → mode-pack scaffold

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

NAME=""
DEST_DIR_REL="skills/owned"
SKILL_TYPE="skill"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) shift; DEST_DIR_REL="$1" ;;
    --type) shift; SKILL_TYPE="$1" ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0
      ;;
    -*)
      printf 'scaffold-skill: unknown flag %s\n' "$1" >&2; exit 2
      ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"
      else printf 'scaffold-skill: extra argument "%s"\n' "$1" >&2; exit 2
      fi
      ;;
  esac
  shift
done

if [ -z "$NAME" ]; then
  printf 'usage: scaffold-skill.sh <name> [--dir <path>] [--type skill|mode-pack]\n' >&2
  exit 2
fi

if ! printf '%s' "$NAME" | grep -qE '^[a-z0-9][a-z0-9._-]*$'; then
  printf 'scaffold-skill: name must be kebab-case (saw: %s)\n' "$NAME" >&2
  exit 2
fi

case "$SKILL_TYPE" in
  skill|mode-pack) ;;
  *) printf 'scaffold-skill: type must be "skill" or "mode-pack" (saw: %s)\n' "$SKILL_TYPE" >&2; exit 2 ;;
esac

TARGET_DIR="$REPO_ROOT/$DEST_DIR_REL/$NAME"
if [ -e "$TARGET_DIR" ]; then
  printf 'scaffold-skill: %s already exists; refusing to overwrite\n' "$TARGET_DIR" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"

# ---------------------------------------------------------------------------
# SKILL.md — seeded from the exemplar with placeholders rewritten
# ---------------------------------------------------------------------------
cat > "$TARGET_DIR/SKILL.md" <<EOF
---
name: $NAME
description: TODO — one sentence (≤ 280 chars) describing what this $SKILL_TYPE does and when to invoke it.
type: $SKILL_TYPE
schema_version: 1
version: 0.1.0
---

# $NAME

TODO — one paragraph describing the skill's domain and how it fits the studio.

## What this skill does

TODO — concrete capability: what the skill produces, given what input.

## What this skill does not do

TODO — explicit boundaries; what callers must not expect.

## Inputs

- TODO — name + type + how supplied (env var, slot, file path).

## Outputs

- TODO — events emitted, files written, stdout shape.

## When to invoke

TODO — the trigger conditions; complement the routing.yaml triggers list.

## Procedure

1. **READ** \`<target-path>\`.
   Before: \`<target-path>\` is set and points to a regular file.
   After:  the file is loaded into context.

2. **CHECK** \`<condition>\`.
   Before: step 1 completed successfully.
   After:  the branch decision has been made.

   Decision:
   | Case | Action |
   |---|---|
   | \`<case-A>\` | PROCEED to step 3 |
   | \`<case-B>\` | BLOCK with \`<error-code>\` |

3. **EMIT** \`${NAME}_completed\` with payload \`{...}\`.
   Before: prior step succeeded.
   After:  one event has been appended to today's event log.

4. **STOP**.
   Before: emit succeeded.
   After:  the agent session terminates.

## Failure modes

| Failure | Classification | Action |
|---|---|---|
| TODO — observable failure | permanent | BLOCK with \`<error-code>\` |
| TODO — observable failure | transient | RETRY once after 250ms; on second failure, ESCALATE |
| TODO — observable failure | ambiguous | ESCALATE to user with context in \`<path>\` |

## See also

- \`_shared/standards/skill-authoring.md\`
- \`_shared/standards/sentinel-vocabulary.md\`
EOF

# ---------------------------------------------------------------------------
# routing.yaml
# ---------------------------------------------------------------------------
cat > "$TARGET_DIR/routing.yaml" <<EOF
schema_version: 1
name: $NAME
invocation:
  slash_command: "/$NAME"
  triggers:
    - "TODO — natural-language phrase that fires this $SKILL_TYPE"
    - "/$NAME"
domains:
  - todo-replace-me
EOF

# ---------------------------------------------------------------------------
# portability.yaml — defaults to claude-code only; widen consciously.
# ---------------------------------------------------------------------------
cat > "$TARGET_DIR/portability.yaml" <<EOF
schema_version: 1
hosts:
  - claude-code
notes: |
  Authored on Claude Code. Widen \`hosts:\` only after the skill body has been
  verified to use no host-specific primitives (run scripts/lint-host-agnostic.sh).
EOF

# ---------------------------------------------------------------------------
# Verify the scaffold passes the linter.
# ---------------------------------------------------------------------------
if [ -x "$SCRIPT_DIR/lint-skill-prose.sh" ]; then
  if ! "$SCRIPT_DIR/lint-skill-prose.sh" "$TARGET_DIR" >/dev/null 2>&1; then
    printf 'scaffold-skill: WARNING — generated skeleton failed lint-skill-prose.sh\n' >&2
    printf '  This is a scaffold regression. Run the linter directly to inspect:\n' >&2
    printf '    scripts/lint-skill-prose.sh %s\n' "${TARGET_DIR#"$REPO_ROOT/"}" >&2
  fi
fi

cat <<EOF
scaffolded: $TARGET_DIR
files:
  - SKILL.md
  - routing.yaml
  - portability.yaml

next:
  1. Replace TODOs in SKILL.md with real content.
  2. Update routing.yaml triggers + domains.
  3. Widen portability.yaml hosts after verifying with scripts/lint-host-agnostic.sh.
  4. Run scripts/lint-skill-prose.sh ${TARGET_DIR#"$REPO_ROOT/"} to validate.
EOF
