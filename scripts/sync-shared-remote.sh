#!/usr/bin/env bash
# sync-shared-remote.sh — push + pull the per-project shared/ tree against a
# private GitHub repo. Implements the multi-machine-sync contract
# (_shared/patterns/multi-machine-sync.md §Sync mechanism — GitHub private
# repo). Append-only partitions guarantee conflict-free merges.
#
# Layout of the remote:
#   <remote>/shared/<project>/<machine-id>/...    (one dir per machine)
#
# Each machine pushes its own partition; pulls everyone else's. Never rewrites
# another partition.
#
# Usage:
#   scripts/sync-shared-remote.sh             # push own + pull others
#   scripts/sync-shared-remote.sh --push-only # push self partition, skip pull
#   scripts/sync-shared-remote.sh --pull-only # pull others, skip push
#
# Config — environment variables:
#   DEV_STUDIO_SYNC_REMOTE    git URL of the private sync repo (required)
#   DEV_STUDIO_SYNC_BRANCH    branch to sync on (default: main)
#   DEV_STUDIO_SYNC_CACHE     local clone path (default: ~/.dev-studio/.runtime/sync-cache)
#
# The remote is never auto-configured. User sets DEV_STUDIO_SYNC_REMOTE once
# via shell rc or per-session.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

PUSH=1
PULL=1
case "${1:-}" in
  --push-only) PULL=0 ;;
  --pull-only) PUSH=0 ;;
  "") ;;
  *)
    printf 'usage: sync-shared-remote.sh [--push-only|--pull-only]\n' >&2
    exit 2
    ;;
esac

if [ -z "${DEV_STUDIO_SYNC_REMOTE:-}" ]; then
  printf 'sync-shared-remote: DEV_STUDIO_SYNC_REMOTE not set — skipping sync\n' >&2
  exit 1
fi

REMOTE_URL="$DEV_STUDIO_SYNC_REMOTE"
BRANCH="${DEV_STUDIO_SYNC_BRANCH:-main}"

if command -v resolve_runtime_global >/dev/null 2>&1; then
  runtime=$(resolve_runtime_global)
else
  runtime="$HOME/.dev-studio/.runtime"
fi
CACHE_DIR="${DEV_STUDIO_SYNC_CACHE:-$runtime/sync-cache}"

project=$(resolve_project 2>/dev/null) || {
  printf 'sync-shared-remote: cannot resolve project — run inside a git repo\n' >&2
  exit 1
}
project_root=$(resolve_project_root_for "$project")
SHARED_ROOT="${DEV_STUDIO_SHARED_ROOT:-$project_root/shared}"
machine_id=$("$SCRIPT_DIR/machine-id.sh") || exit 1

# Provision local clone if missing.
if [ ! -d "$CACHE_DIR/.git" ]; then
  mkdir -p "$(dirname "$CACHE_DIR")"
  git clone --depth 1 --branch "$BRANCH" "$REMOTE_URL" "$CACHE_DIR" 2>/dev/null || {
    # Remote may be empty; fall back to init + remote add.
    rm -rf "$CACHE_DIR"
    git init -q -b "$BRANCH" "$CACHE_DIR"
    git -C "$CACHE_DIR" remote add origin "$REMOTE_URL"
  }
fi

# Always fetch before doing anything else; sync against latest origin state.
# Pull phase: rsync every foreign partition from the clone's shared/<project>/
# into the local project's shared/ tree. Own partition is excluded — a writer
# never consumes its own data via this path.
if [ "$PULL" -eq 1 ]; then
  git -C "$CACHE_DIR" fetch origin "$BRANCH" 2>/dev/null || true
  git -C "$CACHE_DIR" reset --hard "origin/$BRANCH" 2>/dev/null || true
  remote_project="$CACHE_DIR/shared/$project"
  if [ -d "$remote_project" ]; then
    while IFS= read -r partition; do
      [ -z "$partition" ] && continue
      pid=$(basename "$partition")
      [ "$pid" = "$machine_id" ] && continue
      mkdir -p "$SHARED_ROOT/$pid"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$partition/" "$SHARED_ROOT/$pid/"
      else
        # Fallback: copy + prune.
        rm -rf "$SHARED_ROOT/$pid"
        cp -R "$partition" "$SHARED_ROOT/$pid"
      fi
    done < <(find "$remote_project" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  fi
fi

# Push phase: mirror self-partition into the clone, commit, push.
if [ "$PUSH" -eq 1 ]; then
  self_partition="$SHARED_ROOT/$machine_id"
  if [ -d "$self_partition" ]; then
    dest="$CACHE_DIR/shared/$project/$machine_id"
    mkdir -p "$dest"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "$self_partition/" "$dest/"
    else
      rm -rf "$dest"
      cp -R "$self_partition" "$dest"
    fi
    git -C "$CACHE_DIR" add "shared/$project/$machine_id" 2>/dev/null || true
    if ! git -C "$CACHE_DIR" diff --cached --quiet 2>/dev/null; then
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      git -C "$CACHE_DIR" -c user.email="sync@dev-studio" -c user.name="dev-studio-sync" \
        commit -q -m "sync $project/$machine_id at $ts"
      git -C "$CACHE_DIR" push origin "$BRANCH" 2>/dev/null || {
        printf 'sync-shared-remote: push failed (non-fatal — will retry next sync)\n' >&2
      }
    fi
  fi
fi

printf 'sync-shared-remote: ok (project=%s machine=%s push=%d pull=%d)\n' \
  "$project" "$machine_id" "$PUSH" "$PULL"
