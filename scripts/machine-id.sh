#!/usr/bin/env bash
# machine-id.sh — stable machine UUID, written once to
# ~/.dev-studio/.runtime/machine-id and cached thereafter. Used by the
# multi-machine-sync contract (_shared/patterns/multi-machine-sync.md) to
# partition shared state by writer.
#
# Usage:
#   scripts/machine-id.sh              # prints the stable machine-id
#
# First call provisions a UUIDv4 atomically; subsequent calls are a read.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh" 2>/dev/null || true

# Derive the runtime-global dir via the resolver when available; fall back to
# the documented canonical path so the script works even when lib-paths.sh
# isn't sourced (e.g. test fixtures that stub it).
if command -v resolve_runtime_global >/dev/null 2>&1; then
  RUNTIME_DIR=$(resolve_runtime_global)
else
  RUNTIME_DIR="$HOME/.dev-studio/.runtime"
fi

# DEV_STUDIO_MACHINE_ID_FILE is a test-only override — keeps unit fixtures out
# of the user's real ~/.dev-studio/.runtime/ without duplicating the resolver.
ID_FILE="${DEV_STUDIO_MACHINE_ID_FILE:-$RUNTIME_DIR/machine-id}"

# Fast path — already provisioned.
if [ -r "$ID_FILE" ]; then
  id=$(tr -d '[:space:]' < "$ID_FILE")
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
    exit 0
  fi
fi

mkdir -p "$(dirname "$ID_FILE")"

# Provision. Prefer uuidgen (BSD + GNU). Fall back to /proc/sys/kernel/random/uuid
# (Linux) or a constructed UUIDv4 from /dev/urandom. Output must be UUID-like.
gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
    return
  fi
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return
  fi
  # Hand-rolled UUIDv4: 16 random bytes, set version + variant bits, hex-format.
  # Opaque partition key; not cryptographic material.
  local hex
  hex=$(od -An -vtx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
  printf '%s-%s-4%s-%s%s-%s\n' \
    "${hex:0:8}" \
    "${hex:8:4}" \
    "${hex:13:3}" \
    "$(printf '%x' $((0x${hex:16:1} & 0x3 | 0x8)))" \
    "${hex:17:3}" \
    "${hex:20:12}"
}

# Atomic write: gen to a tmp file, use `ln` to publish. `ln` fails if the
# destination already exists, so we can tell the difference between "we won"
# (ln succeeded) and "someone else already published" (ln failed; read their
# content). `mv -n` is unreliable for this — BSD `mv -n` silently no-ops when
# the destination exists even if empty.
tmp=$(mktemp "$(dirname "$ID_FILE")/.machine-id.XXXXXX")
new_id=$(gen_uuid)
printf '%s\n' "$new_id" > "$tmp"
chmod 0644 "$tmp"
if ln "$tmp" "$ID_FILE" 2>/dev/null; then
  rm -f "$tmp"
  printf '%s\n' "$new_id"
else
  # Destination existed — either another process just won the race, or the
  # caller pre-seeded the file (fixture case). Re-read.
  rm -f "$tmp"
  id=$(tr -d '[:space:]' < "$ID_FILE")
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
  else
    # File exists but is empty — overwrite atomically via rename. mv -f
    # succeeds where mv -n silently skipped.
    tmp2=$(mktemp "$(dirname "$ID_FILE")/.machine-id.XXXXXX")
    printf '%s\n' "$new_id" > "$tmp2"
    chmod 0644 "$tmp2"
    mv -f "$tmp2" "$ID_FILE"
    printf '%s\n' "$new_id"
  fi
fi
