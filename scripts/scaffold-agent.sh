#!/usr/bin/env bash
# scaffold-agent.sh <name> — creates a router-pattern-compliant agent skeleton.
#
# Effects:
#   <name>/SKILL.md           router template (singleton-status line, dispatch stub)
#   <name>/modes/.gitkeep
#   <name>/snapshots/.gitkeep
#   docs-surface.json         regenerated (if update-surface-manifest.sh present)
#   GitHub issue              `Build out <name> agent` with labels enhancement,theme/internal

set -u
umask 022

NAME="${1:-}"
if [ -z "$NAME" ]; then
  printf 'usage: scaffold-agent.sh <name>\n' >&2
  exit 2
fi
case "$NAME" in
  *[!a-z0-9-]*|-*|*-|'')
    printf 'error: name must be lowercase kebab-case (saw: %s)\n' "$NAME" >&2
    exit 2
    ;;
esac

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
AGENT_DIR="$REPO_ROOT/$NAME"

if [ -e "$AGENT_DIR" ]; then
  printf 'error: %s already exists — refusing to overwrite\n' "$AGENT_DIR" >&2
  exit 1
fi

mkdir -p "$AGENT_DIR/modes" "$AGENT_DIR/snapshots"
: > "$AGENT_DIR/modes/.gitkeep"
: > "$AGENT_DIR/snapshots/.gitkeep"

cat > "$AGENT_DIR/SKILL.md" <<EOF
---
name: $NAME
description: TODO — one-sentence statement of what this agent does and when to invoke it.
type: agent-router
---

# $NAME

Router for the $NAME agent. Follows the convention in \`_shared/router-pattern.md\` — tiny router, on-demand mode packs, small per-domain snapshots.

Singleton status: **not singleton** (update after evaluating against \`_shared/singleton-invariants.md\`).

## Dispatch

| Sub-command | Mode pack |
|---|---|
| \`/$NAME <mode>\` | \`modes/<mode>.md\` |

Intent detection order:
1. Explicit arg — \`/$NAME <mode>\` always wins.
2. Conversational switch — mid-session, natural-language intent may re-dispatch.
3. Default — TODO: set a sensible default mode before shipping.

## References

- Pattern contract: \`_shared/router-pattern.md\`.
- Singleton rules: \`_shared/singleton-invariants.md\`.
- Enforcement codes: \`_shared/enforcement-contract.md\`.
EOF

if [ -x "$SCRIPT_DIR/update-surface-manifest.sh" ]; then
  "$SCRIPT_DIR/update-surface-manifest.sh" >/dev/null 2>&1 || true
fi

# Tracking issue — best effort; do not block scaffolding on gh availability.
if command -v gh >/dev/null 2>&1; then
  gh issue create \
    --title "Build out $NAME agent" \
    --body "Scaffolded via \`scripts/scaffold-agent.sh $NAME\`. Next steps:\n\n- Add \`modes/<pack>.md\` files for each sub-command.\n- Fill in dispatch table and default mode in \`$NAME/SKILL.md\`.\n- Declare \`snapshots: []\` (or list) in every mode pack frontmatter.\n- Run \`scripts/lint-architecture.sh\` to verify.\n\nPattern: \`_shared/router-pattern.md\`." \
    --label "enhancement,theme/internal" >/dev/null 2>&1 || \
    printf 'warn: could not create tracking issue (gh unauthed?)\n' >&2
fi

cat <<EOF
scaffolded: $AGENT_DIR
next:
  - Add modes/<pack>.md files; one file per sub-command.
  - Fill in the dispatch table and default-mode behavior in $NAME/SKILL.md.
  - Run \`scripts/lint-architecture.sh\` to verify before committing.
EOF
