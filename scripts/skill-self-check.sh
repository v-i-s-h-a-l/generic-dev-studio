#!/usr/bin/env bash
# skill-self-check.sh — verify the deployed skills-root layout matches the
# manifest at _shared/distribution/expected-layout.yaml (#262).
#
# Owned-agent SKILL.md prose references _shared/ and scripts/ as if they
# were reachable at session start. Multi-host distribution (#168, #198)
# ships those companions as symlinks alongside the per-agent dirs at the
# skills-root level. There was no automated check that the layout was
# actually reachable — partial deploys silently degraded to manual-mode
# workarounds and accumulated invisibly-incomplete debriefs / event-log
# emissions until the gap surfaced through a downstream artifact mismatch.
#
# This script runs at session start (invoked from each owned SKILL.md
# bootstrap) and refuses loud when an anchor named in the manifest is
# missing, naming the install command. Manifest-driven so what each agent
# requires lives in one place — adding / renaming an agent dir touches
# the YAML, not 4 separate SKILL.md procedural blocks.
#
# Usage:
#   scripts/skill-self-check.sh <agent>
#     <agent>: one of the names under `agents:` in the manifest
#              (achilles, argus, chanakya, apollo). Companions are checked
#              for every invocation regardless of agent.
#
# Exit codes:
#   0  layout matches the manifest
#   2  one or more anchors missing — the message names them
#   3  manifest unreadable / agent not declared in manifest

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# The skills-root is the parent of scripts/ — the directory that holds
# _shared/, scripts/, and the per-agent dirs. Resolved from the script's
# own location so the check works for any deployment that places this
# script at <skills-root>/scripts/skill-self-check.sh (the canonical
# layout produced by sync-host-skills.sh).
SKILLS_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

AGENT="${1:-}"
[ -z "$AGENT" ] && { printf 'skill-self-check: usage: %s <agent>\n' "$0" >&2; exit 3; }

# AGENT must be a simple identifier — used as a YAML key reference, so reject
# anything that could escape the manifest query. Owned-agent names are fixed
# (achilles / argus / chanakya / apollo / future kebab-case additions); a
# stricter regex than yq's tolerance keeps the surface tight.
case "$AGENT" in
  *[!a-zA-Z0-9_-]*|"")
    printf 'skill-self-check: agent name %q invalid (alphanumeric / underscore / hyphen only)\n' "$AGENT" >&2
    exit 3 ;;
esac

MANIFEST="$SKILLS_ROOT/_shared/distribution/expected-layout.yaml"
if [ ! -r "$MANIFEST" ]; then
  printf 'skill-self-check: manifest not found at %s — run /studio sync to deploy companions\n' "$MANIFEST" >&2
  exit 3
fi

if ! command -v yq >/dev/null 2>&1; then
  # yq is part of the worker-path dep set (REVIEW.md R13). Its absence is a
  # host-config bug, not a layout bug — surface clearly rather than skip.
  printf 'skill-self-check: yq required for manifest parsing — install yq before retrying\n' >&2
  exit 3
fi

# Collect missing anchors so the user sees the full set in one shot rather
# than chasing them one error at a time. Each line: <kind>\t<path>.
missing=""
record_miss() {
  local kind="$1" path="$2"
  if [ -z "$missing" ]; then
    missing="$kind	$path"
  else
    missing="$missing
$kind	$path"
  fi
}

check_dir()  { [ -d "$SKILLS_ROOT/$1" ]                           || record_miss "dir"  "$1"; }
check_file() { [ -f "$SKILLS_ROOT/$1" ] || [ -L "$SKILLS_ROOT/$1" ] || record_miss "file" "$1"; }

# Companions — required for every agent.
while IFS= read -r d; do [ -n "$d" ] && check_dir  "$d"; done < <(yq -r '.companions.required_dirs[]?' "$MANIFEST" 2>/dev/null)
while IFS= read -r f; do [ -n "$f" ] && check_file "$f"; done < <(yq -r '.companions.required_files[]?' "$MANIFEST" 2>/dev/null)

# Adapter (#297) — detect current host from SKILLS_ROOT, validate its
# capabilities manifest is deployed. Resolves by matching SKILLS_ROOT against
# each adapter's global_skill_dir in the manifest. No match = skip (running
# from repo root, not a deployed tree).
_detected_host=""
while IFS= read -r _adapter_host; do
  [ -n "$_adapter_host" ] || continue
  _adapter_skill_dir=$(yq -r ".adapters.\"$_adapter_host\".global_skill_dir // \"\"" "$MANIFEST" 2>/dev/null)
  [ -n "$_adapter_skill_dir" ] || continue
  _adapter_skill_dir="${_adapter_skill_dir/#\~/$HOME}"
  if [ "$SKILLS_ROOT" = "$_adapter_skill_dir" ]; then
    _detected_host="$_adapter_host"
    break
  fi
done < <(yq -r '.adapters | keys | .[]' "$MANIFEST" 2>/dev/null)
if [ -n "$_detected_host" ]; then
  while IFS= read -r f; do [ -n "$f" ] && check_file "$f"; done \
    < <(yq -r ".adapters.\"$_detected_host\".required_files[]?" "$MANIFEST" 2>/dev/null)
fi

# Agent-specific. mikefarah/yq doesn't support --arg, so AGENT (validated
# above to be safe identifier chars only) is interpolated directly.
agent_present=$(yq -r ".agents | has(\"$AGENT\")" "$MANIFEST" 2>/dev/null)
if [ "$agent_present" != "true" ]; then
  printf 'skill-self-check: agent %q not declared in manifest %s\n' "$AGENT" "$MANIFEST" >&2
  exit 3
fi
while IFS= read -r d; do [ -n "$d" ] && check_dir  "$d"; done < <(yq -r ".agents.\"$AGENT\".required_dirs[]?" "$MANIFEST" 2>/dev/null)
while IFS= read -r f; do [ -n "$f" ] && check_file "$f"; done < <(yq -r ".agents.\"$AGENT\".required_files[]?" "$MANIFEST" 2>/dev/null)
while IFS= read -r f; do [ -n "$f" ] && check_file "$f"; done < <(yq -r ".agents.\"$AGENT\".required_modes[]?" "$MANIFEST" 2>/dev/null)

if [ -z "$missing" ]; then
  exit 0
fi

cat >&2 <<EOF
skill-self-check: deployed skill layout incomplete for $AGENT
  skills-root: $SKILLS_ROOT
  manifest:    $MANIFEST

Missing anchors:
EOF
printf '%s\n' "$missing" | awk -F'\t' '{ printf "  %-4s  %s\n", $1":", $2 }' >&2

cat >&2 <<EOF

Fix: run \`/studio sync\` to (re-)fan-out the symlink farm for this host,
or invoke \`scripts/sync-host-skills.sh <host>\` directly. If the host
has never been bootstrapped, run \`/studio-setup\` first.

Refusing to dispatch with a partial deploy — silent degradation
accumulates invisibly-incomplete debriefs and event-log gaps.
EOF

exit 2
