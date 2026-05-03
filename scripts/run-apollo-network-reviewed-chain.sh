#!/usr/bin/env bash
# run-apollo-network-reviewed-chain.sh — one-command Apollo network chain launch.
#
# Usage:
#   scripts/run-apollo-network-reviewed-chain.sh [--dry-run] [--foreground]
#
# Default mode starts the reviewed Apollo network-efficiency chain in the
# background, keeps the machine awake through studio-chain-reviewed.sh, and
# writes a timestamped log plus a stable latest-log symlink.

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

DRY_RUN=0
FOREGROUND=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --foreground) FOREGROUND=1; shift ;;
    -h|--help) usage ;;
    *)
      printf 'run-apollo-network-reviewed-chain: unknown flag %s\n' "$1" >&2
      usage
      ;;
  esac
done

LOGIN_HOME=$(resolve_user_login_home 2>/dev/null || true)
[ -n "$LOGIN_HOME" ] && [ -d "$LOGIN_HOME" ] || {
  printf 'run-apollo-network-reviewed-chain: could not resolve login home\n' >&2
  exit 1
}

log_dir="$(resolve_project_root_for generic-dev-studio)/chain-runs/manual-logs"
mkdir -p "$log_dir"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
suffix="reviewed"
if [ "$DRY_RUN" -eq 1 ]; then
  suffix="reviewed-dry-run"
fi
log_file="$log_dir/apollo-network-efficiency-$suffix-$stamp.log"
latest_log="$log_dir/apollo-network-efficiency-$suffix.latest.log"

cmd=("$SCRIPT_DIR/studio-chain-reviewed.sh" apollo-network-efficiency --host codex --review-host claude-reviewer)
if [ "$DRY_RUN" -eq 1 ]; then
  cmd+=(--dry-run --no-caffeinate)
fi

ln -sfn "$log_file" "$latest_log"

if [ "$FOREGROUND" -eq 1 ]; then
  printf 'run-apollo-network-reviewed-chain: running in foreground\n' | tee "$log_file"
  printf 'run-apollo-network-reviewed-chain: log: %s\n' "$log_file" | tee -a "$log_file"
  set +e
  (
    cd "$REPO_ROOT"
    HOME="$LOGIN_HOME" "${cmd[@]}"
  ) 2>&1 | tee -a "$log_file"
  rc=${PIPESTATUS[0]}
  set -e
  printf 'run-apollo-network-reviewed-chain: exit_code=%s\n' "$rc" | tee -a "$log_file"
  exit "$rc"
fi

nohup bash -lc 'cd "$1" && shift && exec env HOME="$1" "${@:2}"' \
  bash "$REPO_ROOT" "$LOGIN_HOME" "${cmd[@]}" \
  > "$log_file" 2>&1 &
pid=$!

printf 'APOLLO_NETWORK_CHAIN_PID=%s\n' "$pid"
printf 'APOLLO_NETWORK_CHAIN_LOG=%s\n' "$log_file"
printf 'APOLLO_NETWORK_CHAIN_LATEST_LOG=%s\n' "$latest_log"
printf 'tail -f %q\n' "$latest_log"
