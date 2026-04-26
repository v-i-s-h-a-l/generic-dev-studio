#!/usr/bin/env bash
# scaffold-audit.sh <agent> — capability-collision audit for a scaffolded
# agent. Run AFTER populating modes/ but BEFORE committing.
#
# For every mode pack under <agent>/modes/, read its frontmatter `name` and
# `description`, extract verbs/nouns, and grep _shared/schemas/capability-
# manifest.json for similar capabilities on existing agents. For each match,
# require an entry in <agent>/scaffold-decision.md classifying as one of:
#   - reuse      — the existing capability covers it; remove the new mode
#   - extend     — call into the existing capability and add only what's new
#   - divergent  — justified divergence; explain why a new implementation
#
# Blocks (exit 1) when collisions exist without addressed decisions.
# Authoritative rule: _shared/rules/mode-pack-discipline.md (M-2).
#
# Usage:
#   scripts/scaffold-audit.sh <agent>
#       Audit <agent>/modes/ against existing agents. Echoes collisions
#       and exits 1 if scaffold-decision.md is missing or incomplete.

set -u
umask 022

NAME="${1:-}"
if [ -z "$NAME" ]; then
  printf 'usage: scaffold-audit.sh <agent>\n' >&2
  exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
AGENT_DIR="$REPO_ROOT/$NAME"
DECISION_FILE="$AGENT_DIR/scaffold-decision.md"
MANIFEST="$REPO_ROOT/_shared/schemas/capability-manifest.json"

if [ ! -d "$AGENT_DIR" ]; then
  printf 'error: %s does not exist — run scaffold-agent.sh first\n' "$AGENT_DIR" >&2
  exit 2
fi
if [ ! -f "$MANIFEST" ]; then
  printf 'warn: %s missing — run scripts/capability-manifest.sh --regen first\n' "$MANIFEST" >&2
  exit 2
fi

# Collect new mode names + descriptions.
new_modes=$(find "$AGENT_DIR/modes" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
  | while IFS= read -r f; do
      name=$(awk '/^---$/{c++;next} c==1 && /^name:/ { sub(/^name:[ \t]*/, ""); print; exit }' "$f")
      [ -n "$name" ] && printf '%s\t%s\n' "$name" "${f#"$REPO_ROOT/"}"
    done)

if [ -z "$new_modes" ]; then
  printf 'audit: no modes under %s/modes/ — populate first\n' "$NAME" >&2
  exit 0
fi

# Build a lowercase verb/noun list for each new mode and grep the manifest
# for collisions. Manifest contains agents[].modes[].name + .description.
collisions=""
while IFS=$'\t' read -r mode_name mode_path; do
  [ -z "$mode_name" ] && continue
  # Tokenize on hyphens / underscores / spaces. Keep tokens >= 4 chars to
  # avoid noise (it/the/etc).
  tokens=$(printf '%s' "$mode_name" | tr 'A-Z' 'a-z' \
    | tr '_-' '  ' | tr ' ' '\n' | awk 'length($0) >= 4')
  for tok in $tokens; do
    # Match against any other agent's mode name OR description.
    hits=$(jq -r --arg agent "$NAME" --arg tok "$tok" '
      .agents[]
      | select(.name != $agent)
      | .name as $a
      | (.modes // [])[]
      | select((.name | ascii_downcase | contains($tok))
            or ((.description // "") | ascii_downcase | contains($tok)))
      | "  - \($a)/\(.name) — \(.description // "")"
    ' "$MANIFEST" 2>/dev/null)
    if [ -n "$hits" ]; then
      collisions="${collisions}
[$mode_path :: token \"$tok\"]
$hits
"
    fi
  done
done <<EOF
$new_modes
EOF

if [ -z "$collisions" ]; then
  printf 'audit: %s — no capability collisions detected against existing agents\n' "$NAME"
  exit 0
fi

printf 'audit: %s — capability collisions detected:\n' "$NAME"
printf '%s\n' "$collisions"

# Require scaffold-decision.md to be present and non-template.
if [ ! -f "$DECISION_FILE" ]; then
  printf '\nE_SCAFFOLD_DECISION_MISSING:%s::create scaffold-decision.md and classify each collision as reuse|extend|divergent before committing\n' "${DECISION_FILE#"$REPO_ROOT/"}" >&2
  exit 1
fi

# Reject if file still contains template placeholders.
if grep -q '<!-- TEMPLATE: replace this section before committing -->' "$DECISION_FILE"; then
  printf '\nE_SCAFFOLD_DECISION_TEMPLATE:%s::scaffold-decision.md still contains template placeholders — fill in real decisions\n' "${DECISION_FILE#"$REPO_ROOT/"}" >&2
  exit 1
fi

# Each collision token must be referenced (mentioned by mode name) in the
# decision file. Loose check — the file just needs to acknowledge each
# colliding mode name at least once.
missing=""
while IFS=$'\t' read -r mode_name _; do
  [ -z "$mode_name" ] && continue
  if ! grep -q "$mode_name" "$DECISION_FILE"; then
    missing="${missing} ${mode_name}"
  fi
done <<EOF
$new_modes
EOF

if [ -n "$missing" ]; then
  printf '\nE_SCAFFOLD_DECISION_INCOMPLETE:%s::scaffold-decision.md does not address these new modes:%s\n' "${DECISION_FILE#"$REPO_ROOT/"}" "$missing" >&2
  exit 1
fi

printf '\naudit: %s — scaffold-decision.md addresses all collisions; pass\n' "$NAME"
exit 0
