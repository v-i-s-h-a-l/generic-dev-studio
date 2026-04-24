#!/usr/bin/env bash
# snapshot-sync.sh — pull snapshot-test reference images from the canonical
# node to the local machine.
#
# The mini (or whichever machine advertises the `snapshot-canonical` role)
# is the only machine that generates reference images — fixed Xcode,
# fixed simulator, fixed OS. Every other machine that needs to run
# snapshot-test assertions pulls those references down first so the
# assertions compare against the canonical bytes rather than against a
# local environment's pixels.
#
# The script is infrastructure prep: it ships before any snapshot-test
# framework lands in the user's project. When the framework arrives, it
# reads/writes `~/.dev-studio/<project>/snapshots/references/` and this
# sync keeps that dir identical to the canonical machine's copy.
#
# Behaviour:
#   - No registry, no canonical node, or node unreachable → exit 0 with a
#     warn to stderr. The gate that called us doesn't block on this; an
#     empty references dir just means the framework will regenerate or
#     error on its own terms.
#   - Canonical node found and reachable → rsync -a with --delete over
#     SSH, then exit with rsync's status.
#
# Usage:
#   scripts/snapshot-sync.sh [<project-slug>]       # defaults to current repo
#
# Exit codes:
#   0   sync succeeded, or no-op (no canonical node)
#   2   bad args / registry parse error
#   *   propagated from rsync when the sync itself failed

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

PROJECT="${1:-}"
if [ -z "$PROJECT" ]; then
  PROJECT=$(resolve_project 2>/dev/null) || {
    printf 'error: no project resolved and none given; pass a slug explicitly\n' >&2
    exit 2
  }
fi

REGISTRY="$(resolve_runtime_global)/nodes.json"
if [ ! -r "$REGISTRY" ]; then
  printf 'snapshot-sync: no node registry at %s; skipping (nothing to sync from)\n' "$REGISTRY" >&2
  exit 0
fi

command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }
command -v rsync >/dev/null 2>&1 || { printf 'error: rsync required\n' >&2; exit 2; }

# Pick the canonical node. `snapshot-canonical` is a role tag; as a
# fallback we accept `id == "mini"` so the first iteration works before
# anyone has re-tagged the registry. `.enabled == false` is always
# excluded regardless of role match.
NODE_JSON=$(jq -c -e \
  '.nodes[]? | select(.enabled != false) | select((.roles? // []) | index("snapshot-canonical"))' \
  "$REGISTRY" 2>/dev/null | head -n 1)

if [ -z "$NODE_JSON" ]; then
  NODE_JSON=$(jq -c -e \
    '.nodes[]? | select(.enabled != false) | select(.id == "mini")' \
    "$REGISTRY" 2>/dev/null | head -n 1)
fi

if [ -z "$NODE_JSON" ]; then
  printf 'snapshot-sync: no canonical node registered (role=snapshot-canonical or id=mini); skipping\n' >&2
  exit 0
fi

NODE_ID=$(printf '%s' "$NODE_JSON" | jq -r '.id')
HOST=$(printf '%s' "$NODE_JSON" | jq -r '.host // empty')
USER_=$(printf '%s' "$NODE_JSON" | jq -r '.user // empty')

if [ -z "$HOST" ] || [ -z "$USER_" ]; then
  printf 'error: canonical node %s missing host/user in %s\n' "$NODE_ID" "$REGISTRY" >&2
  exit 2
fi

# Health probe first so an unreachable canonical node degrades to a warn
# rather than a 30-second rsync hang. Matches node-dispatch.sh's bound.
TIMEOUT_BIN=""
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout 10"
command -v timeout  >/dev/null 2>&1 && [ -z "$TIMEOUT_BIN" ] && TIMEOUT_BIN="timeout 10"

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

if ! $TIMEOUT_BIN ssh $SSH_OPTS "${USER_}@${HOST}" true >/dev/null 2>&1; then
  printf 'snapshot-sync: canonical node %s (%s) unreachable; skipping\n' "$NODE_ID" "$HOST" >&2
  exit 0
fi

# Both sides resolve through resolve_project_root_for so R3 (no hardcoded
# ~/.dev-studio paths) stays clean. The remote accepts the laptop's
# absolute path because this whole design assumes $HOME parity between
# the dispatcher and the canonical node (same username on both).
REMOTE_REFS="$(resolve_project_root_for "$PROJECT")/snapshots/references/"
LOCAL_REFS="$(resolve_project_root_for "$PROJECT")/snapshots/references/"
mkdir -p "$LOCAL_REFS" 2>/dev/null || { printf 'error: mkdir %s failed\n' "$LOCAL_REFS" >&2; exit 2; }

# --delete keeps the local mirror an exact copy of canonical — stale refs
# get removed, so an assertion that mentions a missing reference produces
# a clear "framework thinks this ref exists but canonical does not"
# failure instead of a false-pass against a stale file. -a preserves
# metadata; -z compresses over the (likely Tailscale) link.
printf 'snapshot-sync: pulling %s:%s → %s\n' "$NODE_ID" "$REMOTE_REFS" "$LOCAL_REFS" >&2
rsync -az --delete -e "ssh $SSH_OPTS" "${USER_}@${HOST}:${REMOTE_REFS}" "$LOCAL_REFS"
