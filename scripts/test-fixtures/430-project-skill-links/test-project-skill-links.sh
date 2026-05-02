#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t project-skill-links.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

REPO="$TMPROOT/repo"
mkdir -p \
  "$REPO/scripts" \
  "$REPO/hosts" \
  "$REPO/.claude/skills/studio" \
  "$REPO/.codex/skills" \
  "$REPO/_shared" \
  "$TMPROOT/home"

cp "$ROOT/scripts/lint-project-skill-links.sh" "$REPO/scripts/lint-project-skill-links.sh"
cp "$ROOT/scripts/sync-host-skills.sh" "$REPO/scripts/sync-host-skills.sh"
cp "$ROOT/scripts/lib-paths.sh" "$REPO/scripts/lib-paths.sh"
chmod +x "$REPO/scripts/lint-project-skill-links.sh" "$REPO/scripts/sync-host-skills.sh"

cat > "$REPO/hosts/registry.yaml" <<'YAML'
codex:
  display_name: "OpenAI Codex CLI"
  detect_binary: codex
  global_skill_dir: "~/.codex/skills"
  project_skill_dir: ".codex/skills"
  routing_file: "AGENTS.md"
  routing_walks_parents: false
  tool_dialect: openai
  status: provisional
YAML

cat > "$REPO/.claude/skills/studio/SKILL.md" <<'MD'
---
name: studio
description: Test project-scoped skill.
type: agent-router
---

# Studio
MD

cat > "$REPO/.claude/skills/studio/portability.yaml" <<'YAML'
schema_version: 1
hosts:
  - codex
scope: project
YAML

missing_err="$TMPROOT/missing.err"
if HOME="$TMPROOT/home" "$REPO/scripts/lint-project-skill-links.sh" --host codex >"$TMPROOT/missing.out" 2>"$missing_err"; then
  echo "FAIL: lint accepted missing .codex/skills/studio" >&2
  exit 1
fi
grep -q 'E_PROJECT_SKILL_LINK:.claude/skills/studio declares host=codex scope=project' "$missing_err" || {
  echo "FAIL: missing-link error did not name the project skill invariant" >&2
  cat "$missing_err" >&2
  exit 1
}
grep -q 'repair: scripts/sync-host-skills.sh codex' "$missing_err" || {
  echo "FAIL: missing-link error did not include repair command" >&2
  cat "$missing_err" >&2
  exit 1
}

HOME="$TMPROOT/home" "$REPO/scripts/lint-project-skill-links.sh" --host codex --repair >"$TMPROOT/repair.out" 2>"$TMPROOT/repair.err"
HOME="$TMPROOT/home" "$REPO/scripts/lint-project-skill-links.sh" --host codex >"$TMPROOT/repaired.out" 2>"$TMPROOT/repaired.err"
rm "$REPO/.codex/skills/studio"

if ! HOME="$TMPROOT/home" "$REPO/scripts/sync-host-skills.sh" codex >"$TMPROOT/sync.out" 2>"$TMPROOT/sync.err"; then
  echo "FAIL: sync-host-skills.sh codex failed" >&2
  cat "$TMPROOT/sync.err" >&2
  exit 1
fi

if [ ! -L "$REPO/.codex/skills/studio" ]; then
  echo "FAIL: sync did not create .codex/skills/studio symlink" >&2
  cat "$TMPROOT/sync.err" >&2
  exit 1
fi

if [ ! -L "$TMPROOT/home/.codex/skills/hosts" ]; then
  echo "FAIL: sync did not deploy hosts companion into global skill dir" >&2
  cat "$TMPROOT/sync.err" >&2
  exit 1
fi

target=$(readlink "$REPO/.codex/skills/studio")
if [ "$target" != "../../.claude/skills/studio" ]; then
  echo "FAIL: expected relative project link, got $target" >&2
  exit 1
fi

HOME="$TMPROOT/home" "$REPO/scripts/lint-project-skill-links.sh" --host codex >"$TMPROOT/fixed.out" 2>"$TMPROOT/fixed.err"

echo "PASS: project-scoped skill links are linted and repairable"
