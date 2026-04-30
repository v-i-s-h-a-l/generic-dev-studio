#!/usr/bin/env bash
# lib-source-sync.sh — translate local paths to remote-stable forms and
# rsync source trees to registered worker nodes before remote dispatch.
#
# Closes #127. Without this, gate scripts dispatched commands like
# `cd /Users/vishalsingh/.dev-studio/...` to remotes whose $HOME differs
# from the manager's (e.g. mini's user is `vishal`, laptop's is
# `vishalsingh` — the path doesn't exist on the remote). This library
# rewrites every dispatched path to an `$HOME`-relative form and pushes
# the source tree to the matching remote location before dispatch.
#
# Why mirror under remote `$HOME`: it's the one stable anchor across
# Macs with mismatched usernames. Both laptop and mini have a `$HOME`;
# `~/.dev-studio/.runtime/worktrees/<task-id>/` is the SAME relative
# tree on both sides, even though the absolute prefix differs.
#
# Exposes:
#   sourcesync_relative_to_home <local-path>
#       Pure: prints the path relative to local $HOME (no leading slash).
#       Returns 0 if path is under $HOME, 1 otherwise (caller decides).
#       Path === $HOME → prints "." (the relative-empty form).
#
#   sourcesync_remote_quoted <relative-path>
#       Pure: prints `"$HOME/<rel>"` ready to be embedded in a remote
#       shell command. The $HOME is preserved literally so the remote
#       shell expands it; the result is single-shell-token safe (rel is
#       wrapped in double-quotes, $HOME stays unquoted for expansion).
#       Use single-quoted string concatenation to keep it literal:
#         remote_cmd='cd '"$(sourcesync_remote_quoted "$REL")"' && ...'
#
#   sourcesync_push <node-id> <local-path>
#       I/O: resolves <node-id> against ~/.dev-studio/.runtime/nodes.json,
#       rsyncs <local-path>/ to the remote at the home-mirrored location,
#       and prints the home-relative path on stdout. Creates the parent
#       directory on the remote first so rsync doesn't error on a missing
#       prefix. Returns 0 on success.
#
#   sourcesync_mkdir_remote <node-id> <relative-path>
#       I/O: ensures `<remote $HOME>/<relative-path>` exists on the
#       remote (mkdir -p). Used to seed DerivedData / cache directories
#       that the dispatched command will write into.
#
#   sourcesync_pull_file <node-id> <remote-rel> <local-path>
#       I/O: copies a single file from `<remote $HOME>/<remote-rel>` to
#       <local-path>. Creates the local parent directory if missing.
#       Returns rsync's exit code. Non-fatal by design — callers
#       typically use `|| true`.
#
#   sourcesync_pull_dir <node-id> <remote-rel> <local-dir>
#       I/O: rsyncs a directory from `<remote $HOME>/<remote-rel>/` to
#       <local-dir>/. Does NOT use --delete — accumulates rather than
#       mirrors. Creates the local directory if missing. Returns rsync's
#       exit code. Non-fatal by design.
#
#   sourcesync_remote_abs <node-id> <remote-rel>
#       I/O: prints the node's absolute path for a home-relative path.
#
#   sourcesync_pull_xcode_artifacts <node-id> <remote-root-rel> <local-root>
#       I/O: finds `.xcarchive` / `.xcresult` directories under the remote
#       root and rsyncs only those directories back to the matching local
#       root. Prints retrieved local paths, one per line.
#
# Design notes:
#   - rsync uses --delete on PUSH so the remote tree is an exact mirror
#     of the local source. PULL functions never --delete — they
#     accumulate artifacts (sidecars, evidence) without wiping local
#     content from other sources.
#   - rsync runs over SSH using the same node-registry credentials
#     (user + host) that node-dispatch.sh uses. No new transport.
#   - DerivedData is left on the remote post-build; gate scripts care
#     about exit code + structured sidecar. Pull functions retrieve
#     specific artifacts (JSON sidecars, AXe evidence) — not bulk
#     DerivedData.
#   - Caller MUST pass --rsh "ssh ..." compatible options? No — we use
#     the system SSH config + agent. ssh-copy-id + tailscale magic-DNS
#     are the prerequisites; this library inherits them.

set -u
umask 022

# Source path resolver if not already loaded.
if ! command -v resolve_runtime_global >/dev/null 2>&1; then
  _LSS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=lib-paths.sh
  . "$_LSS_DIR/lib-paths.sh"
fi

# sourcesync_relative_to_home <local-path>
sourcesync_relative_to_home() {
  local p="${1:?local path required}"
  case "$p" in
    "$HOME")     printf '.\n'; return 0 ;;
    "$HOME"/*)   printf '%s\n' "${p#$HOME/}"; return 0 ;;
    *)
      printf 'sourcesync: %s is not under $HOME — refusing to translate\n' "$p" >&2
      return 1
      ;;
  esac
}

# sourcesync_remote_quoted <rel-path>
# Returns a string ready to embed in a shell command. Format:
# "$HOME"/<quoted-rel> — $HOME is unquoted (remote shell expands), rel
# is double-quoted (safe across spaces / shell metas).
sourcesync_remote_quoted() {
  local rel="${1:?relative path required}"
  case "$rel" in
    .) printf '"$HOME"' ;;
    *) printf '"$HOME/%s"' "$rel" ;;
  esac
}

# sourcesync_push <node-id> <local-path>
sourcesync_push() {
  local node_id="${1:?node-id required}" local_path="${2:?local path required}"
  command -v jq >/dev/null 2>&1 || { printf 'sourcesync: jq required\n' >&2; return 2; }
  command -v rsync >/dev/null 2>&1 || { printf 'sourcesync: rsync required\n' >&2; return 2; }
  [ -d "$local_path" ] || { printf 'sourcesync: %s is not a directory\n' "$local_path" >&2; return 2; }

  local registry; registry="$(resolve_runtime_global)/nodes.json"
  [ -r "$registry" ] || { printf 'sourcesync: node registry not readable: %s\n' "$registry" >&2; return 2; }

  local entry user host
  entry=$(jq -e --arg id "$node_id" '.nodes[]? | select(.id == $id) | select(.enabled != false)' "$registry") \
    || { printf 'sourcesync: unknown or disabled node: %s\n' "$node_id" >&2; return 2; }
  user=$(printf '%s' "$entry" | jq -r '.user')
  host=$(printf '%s' "$entry" | jq -r '.host')

  local rel; rel=$(sourcesync_relative_to_home "$local_path") || return 1

  # Ensure the parent of the rsync target exists on the remote. rsync
  # creates the leaf, but a missing intermediate (e.g. the first task
  # ever to land at ~/.dev-studio/.runtime/worktrees/) errors before
  # the transfer starts.
  local parent_rel; parent_rel=$(dirname "$rel")
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      "$user@$host" "mkdir -p \"\$HOME/$parent_rel\"" >/dev/null 2>&1 \
    || { printf 'sourcesync: ssh mkdir parent failed on %s\n' "$node_id" >&2; return 1; }

  # rsync. -a archives perms+mtime, -q quiet, --delete makes the remote
  # an exact mirror. Trailing slash on source means "contents of dir,
  # not the dir itself" — pairs with the leaf directory created on the
  # remote by the explicit mkdir.
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      "$user@$host" "mkdir -p \"\$HOME/$rel\"" >/dev/null 2>&1 \
    || { printf 'sourcesync: ssh mkdir target failed on %s\n' "$node_id" >&2; return 1; }
  if ! rsync -aq --delete \
        -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
        "$local_path/" "$user@$host:\$HOME/$rel/" 2>/dev/null; then
    printf 'sourcesync: rsync to %s failed\n' "$node_id" >&2
    return 1
  fi
  printf '%s\n' "$rel"
}

# sourcesync_mkdir_remote <node-id> <rel>
sourcesync_mkdir_remote() {
  local node_id="${1:?node-id required}" rel="${2:?relative path required}"
  command -v jq >/dev/null 2>&1 || { printf 'sourcesync: jq required\n' >&2; return 2; }
  local registry; registry="$(resolve_runtime_global)/nodes.json"
  [ -r "$registry" ] || { printf 'sourcesync: node registry not readable: %s\n' "$registry" >&2; return 2; }
  local entry user host
  entry=$(jq -e --arg id "$node_id" '.nodes[]? | select(.id == $id) | select(.enabled != false)' "$registry") \
    || { printf 'sourcesync: unknown or disabled node: %s\n' "$node_id" >&2; return 2; }
  user=$(printf '%s' "$entry" | jq -r '.user')
  host=$(printf '%s' "$entry" | jq -r '.host')
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      "$user@$host" "mkdir -p \"\$HOME/$rel\"" >/dev/null 2>&1
}

# sourcesync_pull_file <node-id> <remote-rel> <local-path>
sourcesync_pull_file() {
  local node_id="${1:?node-id required}" remote_rel="${2:?remote-relative path required}" local_path="${3:?local path required}"
  command -v jq >/dev/null 2>&1 || { printf 'sourcesync: jq required\n' >&2; return 2; }
  command -v rsync >/dev/null 2>&1 || { printf 'sourcesync: rsync required\n' >&2; return 2; }
  local registry; registry="$(resolve_runtime_global)/nodes.json"
  [ -r "$registry" ] || { printf 'sourcesync: node registry not readable: %s\n' "$registry" >&2; return 2; }
  local entry user host
  entry=$(jq -e --arg id "$node_id" '.nodes[]? | select(.id == $id) | select(.enabled != false)' "$registry") \
    || { printf 'sourcesync: unknown or disabled node: %s\n' "$node_id" >&2; return 2; }
  user=$(printf '%s' "$entry" | jq -r '.user')
  host=$(printf '%s' "$entry" | jq -r '.host')
  mkdir -p "$(dirname "$local_path")" 2>/dev/null || true
  rsync -aq \
    -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
    "$user@$host:\$HOME/$remote_rel" "$local_path" 2>/dev/null
}

# sourcesync_pull_dir <node-id> <remote-rel> <local-dir>
sourcesync_pull_dir() {
  local node_id="${1:?node-id required}" remote_rel="${2:?remote-relative path required}" local_dir="${3:?local directory required}"
  command -v jq >/dev/null 2>&1 || { printf 'sourcesync: jq required\n' >&2; return 2; }
  command -v rsync >/dev/null 2>&1 || { printf 'sourcesync: rsync required\n' >&2; return 2; }
  local registry; registry="$(resolve_runtime_global)/nodes.json"
  [ -r "$registry" ] || { printf 'sourcesync: node registry not readable: %s\n' "$registry" >&2; return 2; }
  local entry user host
  entry=$(jq -e --arg id "$node_id" '.nodes[]? | select(.id == $id) | select(.enabled != false)' "$registry") \
    || { printf 'sourcesync: unknown or disabled node: %s\n' "$node_id" >&2; return 2; }
  user=$(printf '%s' "$entry" | jq -r '.user')
  host=$(printf '%s' "$entry" | jq -r '.host')
  mkdir -p "$local_dir" 2>/dev/null || true
  rsync -aq \
    -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
    "$user@$host:\$HOME/$remote_rel/" "$local_dir/" 2>/dev/null
}

# sourcesync_remote_abs <node-id> <remote-rel>
sourcesync_remote_abs() {
  local node_id="${1:?node-id required}" remote_rel="${2:?remote-relative path required}"
  command -v jq >/dev/null 2>&1 || { printf 'sourcesync: jq required\n' >&2; return 2; }
  local registry; registry="$(resolve_runtime_global)/nodes.json"
  [ -r "$registry" ] || { printf 'sourcesync: node registry not readable: %s\n' "$registry" >&2; return 2; }
  local entry user host
  entry=$(jq -e --arg id "$node_id" '.nodes[]? | select(.id == $id) | select(.enabled != false)' "$registry") \
    || { printf 'sourcesync: unknown or disabled node: %s\n' "$node_id" >&2; return 2; }
  user=$(printf '%s' "$entry" | jq -r '.user')
  host=$(printf '%s' "$entry" | jq -r '.host')
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      "$user@$host" "printf '%s\n' \"\$HOME/$remote_rel\"" 2>/dev/null
}

# sourcesync_pull_xcode_artifacts <node-id> <remote-root-rel> <local-root>
sourcesync_pull_xcode_artifacts() {
  local node_id="${1:?node-id required}" remote_root_rel="${2:?remote root required}" local_root="${3:?local root required}"
  command -v jq >/dev/null 2>&1 || { printf 'sourcesync: jq required\n' >&2; return 2; }
  command -v rsync >/dev/null 2>&1 || { printf 'sourcesync: rsync required\n' >&2; return 2; }
  local registry; registry="$(resolve_runtime_global)/nodes.json"
  [ -r "$registry" ] || { printf 'sourcesync: node registry not readable: %s\n' "$registry" >&2; return 2; }
  local entry user host
  entry=$(jq -e --arg id "$node_id" '.nodes[]? | select(.id == $id) | select(.enabled != false)' "$registry") \
    || { printf 'sourcesync: unknown or disabled node: %s\n' "$node_id" >&2; return 2; }
  user=$(printf '%s' "$entry" | jq -r '.user')
  host=$(printf '%s' "$entry" | jq -r '.host')

  local artifacts
  artifacts=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      "$user@$host" "cd \"\$HOME/$remote_root_rel\" 2>/dev/null && find . -type d \( -name '*.xcarchive' -o -name '*.xcresult' \) -print" 2>/dev/null) || return 1
  [ -n "$artifacts" ] || return 0

  local artifact rel local_dir
  while IFS= read -r artifact; do
    [ -z "$artifact" ] && continue
    rel="${artifact#./}"
    [ -z "$rel" ] && continue
    local_dir="$local_root/$rel"
    sourcesync_pull_dir "$node_id" "$remote_root_rel/$rel" "$local_dir" 2>/dev/null || continue
    printf '%s\n' "$local_dir"
  done <<EOF
$artifacts
EOF
}
