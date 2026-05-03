#!/usr/bin/env bash
# spawn-worker.sh — host-agnostic Achilles dispatch.
#
# Wraps the existing achilles-worker.sh with capability-manifest validation
# and (for non-reference hosts) a fresh-session spawn via the host's
# spawn_command. NOT env-scrubbed: Achilles needs git auth (GH_TOKEN /
# .netrc / SSH agent) to push, so secrets are passed through. The sandbox
# floor is enforced from the manifest instead — sandbox_profile must be at
# least workspace-write (or host-native on the reference host).
#
# Contract:
#   scripts/spawn-worker.sh <brief-id> [--wait] [--force-build] [--ignore-build-debt]
#
# Behaviour:
#   1. Resolve $STUDIO_HOST (default claude-code) → load capabilities.yaml.
#   2. Achilles security floor: sandbox_profile ∈ {workspace-write, full},
#      OR sandbox_profile=host-native on the reference host (claude-code).
#      Refuse loudly otherwise.
#   3. Reference host: exec achilles-worker.sh directly (no fresh session) —
#      preserves byte-identical behaviour for STUDIO_HOST=claude-code, which
#      H10 conformance checks against a recorded baseline.
#   4. Other hosts: exec the host's spawn_command with `/dev-studio worker <brief>` as
#      the prompt. The host adapter is responsible for loading the achilles
#      skill in the spawned session.

set -u
umask 022

usage() {
  printf 'usage: spawn-worker.sh <brief-id> [--wait] [--force-build] [--ignore-build-debt]\n' >&2
  exit 2
}

[ $# -ge 1 ] || usage
BRIEF_ID="$1"
shift

FORWARD_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --wait|--force-build|--ignore-build-debt) FORWARD_ARGS+=("$1"); shift ;;
    *) printf 'spawn-worker: unknown flag %s\n' "$1" >&2; usage ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

HOST="${STUDIO_HOST:-claude-code}"
manifest=$(resolve_capabilities_manifest "$HOST" "$REPO_ROOT") || {
  printf 'spawn-worker: host "%s" has no capabilities_path in registry\n' "$HOST" >&2; exit 1
}
host_dir=$(dirname "$manifest")
[ -f "$manifest" ] || { printf 'spawn-worker: missing %s\n' "$manifest" >&2; exit 1; }

yaml_field() {
  grep -E "^${2}:[[:space:]]" "$1" 2>/dev/null \
    | head -1 \
    | sed "s/^${2}:[[:space:]]*//" \
    | tr -d '"'"'"
}
SPAWN_COMMAND=$(yaml_field "$manifest" spawn_command)
SANDBOX_PROFILE=$(yaml_field "$manifest" sandbox_profile)
[ -n "$SPAWN_COMMAND" ] || { printf 'spawn-worker: %s missing spawn_command\n' "$manifest" >&2; exit 1; }

# Achilles sandbox floor: workspace-write or full, with host-native
# permitted only on the documented-exempt reference host.
case "$SANDBOX_PROFILE" in
  workspace-write|full)
    ;;
  host-native)
    if [ "$HOST" != "claude-code" ]; then
      printf 'spawn-worker: refuse — host=%s declares sandbox_profile=host-native; worker requires workspace-write or full on non-reference hosts (see hosts/ADAPTER-SPEC.md §worker security floor).\n' "$HOST" >&2
      exit 1
    fi
    ;;
  *)
    printf 'spawn-worker: refuse — host=%s declares sandbox_profile=%s; does not satisfy worker security floor (workspace-write or full required).\n' \
      "$HOST" "$SANDBOX_PROFILE" >&2
    exit 1
    ;;
esac

# Reference host: use the local worker loop.
if [ "$HOST" = "claude-code" ] && [ -x "$SCRIPT_DIR/achilles-worker.sh" ]; then
  exec "$SCRIPT_DIR/achilles-worker.sh" "$BRIEF_ID" "${FORWARD_ARGS[@]}"
fi

# Non-reference host: spawn fresh session. spawn_command is whitespace-split
# into argv; the prompt routes through the v2 worker role.
# shellcheck disable=SC2206
spawn_argv=( $SPAWN_COMMAND )

# Concatenate flags into a single prompt string. The receiving v2 router
# resolves the worker role contract.
prompt="/dev-studio worker $BRIEF_ID"
for a in "${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}"; do
  prompt="$prompt $a"
done

exec "${spawn_argv[@]}" "$prompt"
