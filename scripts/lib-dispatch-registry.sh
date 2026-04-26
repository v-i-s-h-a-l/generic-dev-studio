#!/usr/bin/env bash
# lib-dispatch-registry.sh — laptop-side registry for remote dispatch UUIDs (#270).
#
# Each remote dispatch (`node-dispatch.sh` SSH branch) generates a UUID per
# #269. This library records that UUID + its dispatch metadata into a
# machine-global per-dispatch JSON file so #147-C (reconnect-and-harvest)
# can look up prior runs without re-asking the worker.
#
# Schema of one entry:
#   {
#     "uuid":           "<lowercase uuid>",
#     "node":           "<node-id>",
#     "task_id":        "<task-id>",
#     "dispatched_at":  "<ISO-8601 Z>",
#     "status":         "in-flight" | "passed" | "failed" | "aborted",
#     "terminated_at":  "<ISO-8601 Z>"   // appended on terminal mark
#   }
#
# Writes are atomic via mv-from-tmp so a concurrent reader (#147-C) never
# observes a partial JSON file.
#
# Path scope (R4 carve-out): `~/.dev-studio/.runtime/dispatch-registry/`.
# The dispatch UUID has no project — it's a property of a (node,
# laptop-session) pair — so the registry is machine-global. Sibling of the
# existing per-dispatch artifacts on the worker (`.runtime/logs/<uuid>.{log,exit}`).
#
# Public API:
#   dispatch_registry_dir          prints the registry root
#   dispatch_registry_path_for     prints the JSON path for a given UUID
#   dispatch_registry_record       writes the in-flight entry (atomic)
#   dispatch_registry_mark         updates an existing entry's status (atomic)

[ "${_LIB_DISPATCH_REGISTRY_LOADED:-}" = "1" ] && return 0
_LIB_DISPATCH_REGISTRY_LOADED=1

# resolve_runtime_global comes from lib-paths.sh — caller sources both.
if ! type resolve_runtime_global >/dev/null 2>&1; then
  printf 'lib-dispatch-registry.sh: lib-paths.sh must be sourced first\n' >&2
  return 1
fi

dispatch_registry_dir() {
  printf '%s\n' "$(resolve_runtime_global)/dispatch-registry"
}

dispatch_registry_path_for() {
  local uuid="${1:?usage: dispatch_registry_path_for <uuid>}"
  printf '%s\n' "$(dispatch_registry_dir)/$uuid.json"
}

# Write the initial in-flight entry. Atomic: write tmp, then mv. A reader
# (#147-C) never observes a partial line.
#
# Returns 0 on success, 1 on any I/O failure. Failure is best-effort —
# losing the registry write must not break dispatch (the worker still has
# `.runtime/logs/<uuid>.{log,exit}` per #269; the registry is the laptop-side
# join key, not the source of truth).
dispatch_registry_record() {
  local uuid="${1:?usage: dispatch_registry_record <uuid> <node> <task_id>}"
  local node="${2:?usage: dispatch_registry_record <uuid> <node> <task_id>}"
  local task_id="${3:?usage: dispatch_registry_record <uuid> <node> <task_id>}"
  # `path` is a zsh special-parameter array (alias of PATH); avoid the name
  # entirely so this lib remains source-clean from zsh callers (REVIEW R5).
  local dir _path _tmp ts
  dir=$(dispatch_registry_dir) || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  _path="$dir/$uuid.json"
  _tmp="$_path.tmp.$$"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"uuid":"%s","node":"%s","task_id":"%s","dispatched_at":"%s","status":"in-flight"}\n' \
    "$uuid" "$node" "$task_id" "$ts" > "$_tmp" 2>/dev/null \
    && mv "$_tmp" "$_path" 2>/dev/null
}

# Update an existing entry's status to a terminal state and stamp
# terminated_at. Atomic via mv. Returns 1 if the entry doesn't exist
# (e.g. dispatch fell back to local before reaching the registry write).
#
# jq is the preferred path so unknown future fields survive the rewrite.
# A POSIX sed fallback handles the rare jq-absent host — both gates source
# this only on dispatch paths that already require jq for the node registry,
# but the fallback keeps the helper itself dependency-light.
dispatch_registry_mark() {
  local uuid="${1:?usage: dispatch_registry_mark <uuid> <status>}"
  # zsh reserves `status` and `path` as read-only special parameters;
  # underscore-prefix the locals so this lib sources cleanly from both
  # shells (REVIEW R5).
  local _status="${2:?usage: dispatch_registry_mark <uuid> <status>}"
  local _path _tmp ts
  _path=$(dispatch_registry_path_for "$uuid") || return 1
  [ -r "$_path" ] || return 1
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _tmp="$_path.tmp.$$"
  if command -v jq >/dev/null 2>&1; then
    jq -c --arg s "$_status" --arg t "$ts" \
      '.status = $s | .terminated_at = $t' "$_path" > "$_tmp" 2>/dev/null \
      && mv "$_tmp" "$_path" 2>/dev/null
  else
    # Replace status in place; append terminated_at if absent. The two-pass
    # sed keeps the JSON one-line and avoids a partial overwrite if the
    # entry already carried a terminated_at from a prior mark (idempotent).
    sed -E 's/"status":"[^"]*"/"status":"'"$_status"'"/' "$_path" \
      | sed -E '/"terminated_at"/!s/}$/,"terminated_at":"'"$ts"'"}/' \
      | sed -E 's/"terminated_at":"[^"]*"/"terminated_at":"'"$ts"'"/' \
      > "$_tmp" 2>/dev/null \
      && mv "$_tmp" "$_path" 2>/dev/null
  fi
}
