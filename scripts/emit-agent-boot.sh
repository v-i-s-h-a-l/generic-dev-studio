#!/usr/bin/env bash
# emit-agent-boot.sh — emit the agent_boot event at first write of a session.
#
# Usage:
#   scripts/emit-agent-boot.sh <agent> <session-id>
#
# Idempotent per session via a sentinel file at:
#   ~/.dev-studio/<project>/.runtime/agent-boot-sent-<session-id>
#
# Per #210, skill_version is read from a single source of truth — the
# `version:` field in <agent>/SKILL.md frontmatter. Callers do not pass
# skill_version; ad-hoc strings are how the 11-distinct-values bug landed
# (analysis/2026-04-25.md Anomaly 2). When the parse fails, emit the
# sentinel `unresolved` rather than an ambiguous `unknown` / `---`.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

AGENT="${1:?usage: emit-agent-boot.sh <agent> <session-id>}"
SESSION_ID="${2:?session-id required}"

case "$AGENT" in
  chanakya|achilles|argus) ;;
  *) printf 'error: invalid agent "%s" (must be chanakya|achilles|argus)\n' "$AGENT" >&2; exit 2 ;;
esac

# Resolve skill_version from <agent>/SKILL.md — the SSOT per #210.
# Failures (missing file, no version field, non-semver value) collapse to
# the `unresolved` sentinel so analytics keyed on skill_version stay joinable
# without inventing fake versions.
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'
SKILL_MD="$REPO_ROOT/$AGENT/SKILL.md"
SKILL_VERSION="unresolved"
if [ -f "$SKILL_MD" ]; then
  parsed=$(awk '
    BEGIN { in_fm=0 }
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm==1 && $0=="---" { exit }
    in_fm==1 && /^version:[[:space:]]/ {
      sub(/^version:[[:space:]]+/, "", $0)
      gsub(/^["'\'']|["'\'']$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$SKILL_MD" 2>/dev/null)
  if [ -n "$parsed" ] && printf '%s' "$parsed" | grep -Eq "$SEMVER_RE"; then
    SKILL_VERSION="$parsed"
  fi
fi
if [ "$SKILL_VERSION" = "unresolved" ]; then
  printf 'warn: emit-agent-boot: skill_version unresolved for %s (missing/non-semver version: in %s) — analytics will key on "unresolved"\n' "$AGENT" "$SKILL_MD" >&2
fi

# Resolve the project-scoped sentinel dir. Failing to resolve is fatal —
# we'd otherwise silently double-emit across sessions.
PROJECT=$(resolve_project 2>/dev/null) || {
  printf 'error: no project resolved — cannot locate sentinel\n' >&2
  exit 2
}
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
SENTINEL_DIR="$PROJECT_ROOT/.runtime"
SENTINEL="$SENTINEL_DIR/agent-boot-sent-$SESSION_ID"

if [ -f "$SENTINEL" ]; then
  exit 0
fi

# Stamp session start-ts unconditionally — every path (task-mode dispatch,
# waived merge, direct mode, rescue) flows through this hook before any other
# session write. Downstream emit-agent-session-completed.sh reads this file
# to compute duration_s. Kept separate from the agent-boot event payload so
# the event stays minimal per _shared/contracts/agent-boot.md.
START_STAMP=$(resolve_session_start_stamp "$SESSION_ID" 2>/dev/null) || START_STAMP=""
if [ -n "$START_STAMP" ]; then
  mkdir -p "$(dirname "$START_STAMP")" 2>/dev/null || true
  [ -f "$START_STAMP" ] || date -u +%s > "$START_STAMP" 2>/dev/null || true
fi

# git_sha is the studio repo's short HEAD. We resolve via SCRIPT_DIR (the
# script always ships with the studio repo); cwd-based fallback was removed
# because Achilles worktrees would resolve cwd to the *user's* project repo.
if [ -d "$REPO_ROOT/.git" ] || [ -f "$REPO_ROOT/.git" ]; then
  GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
else
  GIT_SHA="unknown"
fi

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

AGENT_ESC=$(json_escape "$AGENT")
SV_ESC=$(json_escape "$SKILL_VERSION")
GS_ESC=$(json_escape "$GIT_SHA")

DATA_JSON=$(printf '{"schema_version":{"name":"agent-boot","version":"1.0.0","min_reader":"1.0.0","deprecated_at":null},"agent":"%s","git_sha":"%s","skill_version":"%s"}' \
  "$AGENT_ESC" "$GS_ESC" "$SV_ESC")

if ! append_event "$AGENT" agent_boot "" "$DATA_JSON" 2>/dev/null; then
  printf 'warn: append_event failed — agent_boot not written\n' >&2
fi

mkdir -p "$SENTINEL_DIR" 2>/dev/null || true
: > "$SENTINEL" 2>/dev/null || true
