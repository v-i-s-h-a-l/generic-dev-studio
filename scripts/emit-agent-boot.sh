#!/usr/bin/env bash
# emit-agent-boot.sh — emit the agent_boot event at first write of a session.
#
# Usage:
#   scripts/emit-agent-boot.sh <agent> <session-id> <skill-version>
#
# Idempotent per session via a sentinel file at:
#   ~/.dev-studio/<project>/.runtime/agent-boot-sent-<session-id>
#
# The payload is the minimal 3-field form (agent, git_sha, skill_version)
# per Q3 of PHASE-2-6-PLAN.md — expanded only when a real debugging need
# lands.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

AGENT="${1:?usage: emit-agent-boot.sh <agent> <session-id> <skill-version>}"
SESSION_ID="${2:?session-id required}"
SKILL_VERSION="${3:?skill-version required}"

case "$AGENT" in
  chanakya|achilles|argus) ;;
  *) printf 'error: invalid agent "%s" (must be chanakya|achilles|argus)\n' "$AGENT" >&2; exit 2 ;;
esac

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
  # Already emitted for this session. Silent no-op.
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
  # Only stamp if absent — idempotent like the sentinel.
  [ -f "$START_STAMP" ] || date -u +%s > "$START_STAMP" 2>/dev/null || true
fi

# Resolve git_sha of the studio repo. Caller may override via
# ACHILLES_STUDIO_REPO; otherwise walk up from this script to find a git dir.
# Final fallback is the current working git repo.
STUDIO_REPO="${ACHILLES_STUDIO_REPO:-}"
if [ -z "$STUDIO_REPO" ]; then
  STUDIO_REPO=$(cd "$SCRIPT_DIR/.." 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || STUDIO_REPO=""
fi
if [ -z "$STUDIO_REPO" ]; then
  STUDIO_REPO=$(git rev-parse --show-toplevel 2>/dev/null) || STUDIO_REPO=""
fi
if [ -n "$STUDIO_REPO" ]; then
  GIT_SHA=$(git -C "$STUDIO_REPO" rev-parse --short HEAD 2>/dev/null || echo "unknown")
else
  GIT_SHA="unknown"
fi

# Escape strings for JSON.
json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

AGENT_ESC=$(json_escape "$AGENT")
SV_ESC=$(json_escape "$SKILL_VERSION")
SID_ESC=$(json_escape "$SESSION_ID")
GS_ESC=$(json_escape "$GIT_SHA")

DATA_JSON=$(printf '{"schema_version":{"name":"agent-boot","version":"1.0.0","min_reader":"1.0.0","deprecated_at":null},"agent":"%s","git_sha":"%s","skill_version":"%s"}' \
  "$AGENT_ESC" "$GS_ESC" "$SV_ESC")

# Emit via lib-paths' append_event so the canonical event-log path is used.
# Task field is empty string for a session-level event.
if ! append_event "$AGENT" agent_boot "" "$DATA_JSON" 2>/dev/null; then
  printf 'warn: append_event failed — agent_boot not written\n' >&2
  # Still touch the sentinel to avoid retry loops that never succeed.
fi

mkdir -p "$SENTINEL_DIR" 2>/dev/null || true
: > "$SENTINEL" 2>/dev/null || true
