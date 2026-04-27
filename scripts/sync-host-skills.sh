#!/usr/bin/env bash
# sync-host-skills.sh — fan out canonical skill roots to a host's discovery dir.
#
# For each skill that declares this host in its portability.yaml, create or
# verify a symlink at the host's global skill_dir (per hosts/registry.yaml).
# Stale symlinks (skills that no longer declare this host, or canonical roots
# that no longer exist) are removed. Companion content (_shared, scripts) is
# always linked alongside skills so SKILL.md prose like `_shared/...` resolves.
#
# After linking, injects skill-routing instructions from _shared/skill-routing.md
# into each host's global instructions file (global_instructions_path in
# registry.yaml) between <!-- studio:skill-routing:start/end --> markers.
# This makes skills *discoverable* (the AI knows when to use them), not just
# *available* (the files exist on disk).
#
# Idempotent: a no-op when state is already correct. Self-validating: the
# audit at the end reports any drift; an exit non-zero means the symlink farm
# does not match the declared portability.
#
# Usage:
#   scripts/sync-host-skills.sh <host>
#                                            # apply changes; exit non-zero on
#                                              audit failure
#   scripts/sync-host-skills.sh <host> --dry-run
#                                            # print intended changes, don't
#                                              touch the filesystem
#   scripts/sync-host-skills.sh <host> --audit-only
#                                            # skip create/remove; only audit
#   scripts/sync-host-skills.sh --all
#                                            # apply for every host in
#                                              hosts/registry.yaml
#
# Exit codes:
#   0  symlink farm matches declared portability after the run
#   1  audit found drift the script could not reconcile (manual review needed)
#   2  bad invocation (missing host, missing registry, etc.)

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REGISTRY="$REPO_ROOT/hosts/registry.yaml"

if ! command -v yq >/dev/null 2>&1; then
  printf 'sync-host-skills: yq is required\n' >&2
  exit 2
fi
[ -f "$REGISTRY" ] || { printf 'sync-host-skills: %s missing\n' "$REGISTRY" >&2; exit 2; }

ROUTING_SOURCE="$REPO_ROOT/_shared/skill-routing.md"
ROUTING_MARKER_START="<!-- studio:skill-routing:start -->"
ROUTING_MARKER_END="<!-- studio:skill-routing:end -->"

HOST=""
DRY_RUN=0
AUDIT_ONLY=0
ALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=1 ;;
    --audit-only) AUDIT_ONLY=1 ;;
    --all)        ALL=1 ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    -*)           printf 'sync-host-skills: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)
      if [ -z "$HOST" ]; then HOST="$1"
      else printf 'sync-host-skills: extra argument "%s"\n' "$1" >&2; exit 2
      fi ;;
  esac
  shift
done

if [ "$ALL" -eq 1 ] && [ -n "$HOST" ]; then
  printf 'sync-host-skills: --all and explicit host are mutually exclusive\n' >&2; exit 2
fi
if [ "$ALL" -eq 0 ] && [ -z "$HOST" ]; then
  printf 'usage: sync-host-skills.sh <host> [--dry-run|--audit-only]  |  --all\n' >&2; exit 2
fi

# ---------------------------------------------------------------------------
# Companion content — sibling dirs that skills reference via relative paths.
# These are always linked into a host's skill_dir regardless of portability.
# Keep this list small; it's the boundary between content and code.
# ---------------------------------------------------------------------------
COMPANIONS=(_shared scripts)

# Canonical skill roots — directories containing a SKILL.md AND optionally a
# portability.yaml. A root may be a top-level studio agent (achilles, argus,
# chanakya, apollo, …), a project-scoped vendor skill (.claude/skills/<name>),
# an owned skill (skills/owned/<name>), or a vendored skill
# (skills/vendored/<author>/<name>).
#
# Top-level agents are discovered automatically (maxdepth 2 from repo root,
# excluding non-agent dirs). Adding a new top-level agent dir with a SKILL.md
# is sufficient — no manual update to this script required.
candidate_roots() {
  ( cd "$REPO_ROOT" && {
      # Auto-discover top-level agent dirs (any direct child with a SKILL.md).
      # Exclude companion dirs (_shared, scripts), tool dirs (.git, .claude at
      # depth-1 since its skills are handled below), and test/doc dirs.
      find . -maxdepth 2 -name 'SKILL.md' -type f \
        -not -path './.git/*' \
        -not -path './.claude/*' \
        -not -path './skills/*' \
        -not -path './_shared/*' \
        -not -path './tests/*' \
        -not -path './docs*' \
        2>/dev/null
      # Project-scoped vendor skills, owned skills, and vendored skills
      # (live deeper than maxdepth 2).
      find .claude/skills skills/owned skills/vendored \
        -maxdepth 4 -name 'SKILL.md' -type f 2>/dev/null
    } \
    | while IFS= read -r f; do dirname "$f"; done \
    | sort -u )
}

skill_declares_host() {
  # $1 = skill dir relative to repo root, $2 = host slug
  # NOTE: bash 3.2 expands locals on the same `local` line in declaration
  # order BUT does not guarantee prior locals are visible to later expansions
  # on the same physical line. Splitting `portability` onto its own line
  # ensures $rel is bound before substitution.
  local rel="$1" host="$2"
  local portability="$REPO_ROOT/$rel/portability.yaml"
  if [ ! -f "$portability" ]; then
    [ "$host" = "claude-code" ] && return 0   # default for unmigrated skills
    return 1
  fi
  yq -r '.hosts[]' "$portability" 2>/dev/null | grep -Fxq -e "$host" -e "all"
}

resolve_skill_dir() {
  # $1 = host. Prints the absolute path of the host's global skill_dir,
  # expanding ~ to $HOME.
  local host="$1" path
  path=$(yq -r ".\"$host\".global_skill_dir" "$REGISTRY" 2>/dev/null)
  [ -z "$path" ] || [ "$path" = "null" ] && return 1
  printf '%s\n' "${path/#\~/$HOME}"
}

resolve_project_skill_dir() {
  # $1 = host. Prints the absolute path of the host's project skill_dir
  # (<repo>/<project_skill_dir>).
  local host="$1" path
  path=$(yq -r ".\"$host\".project_skill_dir" "$REGISTRY" 2>/dev/null)
  [ -z "$path" ] || [ "$path" = "null" ] && return 1
  printf '%s\n' "$REPO_ROOT/$path"
}

skill_scope() {
  # $1 = skill dir relative to repo root. Returns "global" (default) or "project".
  local rel="$1"
  local portability="$REPO_ROOT/$rel/portability.yaml"
  if [ ! -f "$portability" ]; then printf 'global\n'; return; fi
  local scope
  scope=$(yq -r '.scope // "global"' "$portability" 2>/dev/null)
  [ -z "$scope" ] || [ "$scope" = "null" ] && scope="global"
  printf '%s\n' "$scope"
}

ensure_dir() {
  local d="$1"
  [ -d "$d" ] && return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] mkdir -p %s\n' "$d"
  else
    mkdir -p "$d"
  fi
}

ensure_link() {
  # $1 = canonical absolute path, $2 = symlink absolute path. Idempotent.
  # Drift-safe: never overwrites a non-symlink or a symlink to an unexpected
  # target.
  local src="$1" dst="$2" existing
  if [ ! -e "$src" ]; then
    printf 'MISSING_CANONICAL:%s (skipping link %s)\n' "$src" "$dst" >&2
    return 1
  fi
  if [ -L "$dst" ]; then
    existing=$(readlink "$dst")
    [ "$existing" = "$src" ] && return 0
    printf 'DRIFT:%s -> %s (expected %s) — leaving in place; reconcile manually\n' \
      "$dst" "$existing" "$src" >&2
    return 1
  fi
  if [ -e "$dst" ]; then
    printf 'CONFLICT:%s exists and is not a symlink — leaving in place\n' "$dst" >&2
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] ln -s %s %s\n' "$src" "$dst"
  else
    ln -s "$src" "$dst"
  fi
  return 0
}

remove_stale() {
  # Remove symlinks in $dir that point at canonical roots that no longer
  # belong here. A symlink belongs in $dir iff:
  #   - target is a canonical skill root inside $REPO_ROOT
  #   - skill declares $host
  #   - skill's scope matches $expected_scope
  #   - companion (_shared / scripts) is always allowed in $expected_scope=global
  #
  # Other content in $dir (regular files, non-studio dirs, foreign symlinks)
  # is left alone — we only own what we previously created.
  local host="$1" dir="$2" expected_scope="${3:-global}"
  local link target name skill_rel scope
  [ -d "$dir" ] || return 0
  for link in "$dir"/*; do
    [ -L "$link" ] || continue
    target=$(readlink "$link")
    case "$target" in
      "$REPO_ROOT"/*) : ;;
      *) continue ;;            # foreign symlink; not ours to manage
    esac
    name=$(basename "$link")
    skill_rel="${target#"$REPO_ROOT/"}"
    # Companions live in global scope only.
    case "$name" in
      _shared|scripts)
        if [ "$expected_scope" = "global" ] && [ -d "$target" ]; then continue; fi
        ;;
    esac
    # Skill: declared portable + scope match + canonical present → keep
    if [ -d "$target" ] && [ -f "$target/SKILL.md" ]; then
      if skill_declares_host "$skill_rel" "$host"; then
        scope=$(skill_scope "$skill_rel")
        if [ "$scope" = "$expected_scope" ]; then continue; fi
      fi
    fi
    # Otherwise: stale; remove.
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '[dry-run] rm %s (stale: %s)\n' "$link" "$target"
    else
      rm "$link"
      printf 'removed stale symlink: %s -> %s\n' "$link" "$target" >&2
    fi
  done
}

audit_host() {
  # Walk the canonical roots that declare this host and confirm a symlink
  # exists. Walk the host's skill_dir and confirm every studio-owned symlink
  # resolves to a known canonical root. Mismatches go to stderr; tally returns
  # via stdout for the caller.
  local host="$1" skill_dir="$2"
  local errors=0
  local rel name target

  local project_skill_dir scope expected_dir
  project_skill_dir=$(resolve_project_skill_dir "$host" || true)

  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    if ! skill_declares_host "$rel" "$host"; then continue; fi
    name=$(basename "$rel")
    scope=$(skill_scope "$rel")
    if [ "$scope" = "project" ]; then
      [ -z "$project_skill_dir" ] && continue
      expected_dir="$project_skill_dir"
      # Canonical at the project skill_dir itself is its own discovery path.
      [ "$REPO_ROOT/$rel" = "$expected_dir/$name" ] && continue
    else
      expected_dir="$skill_dir"
    fi
    target="$expected_dir/$name"
    if [ ! -L "$target" ] || [ "$(readlink "$target")" != "$REPO_ROOT/$rel" ]; then
      printf 'AUDIT_MISSING:%s declares host=%s scope=%s but symlink %s missing or wrong\n' \
        "$rel" "$host" "$scope" "$target" >&2
      errors=$((errors + 1))
    fi
  done < <(candidate_roots)

  for c in "${COMPANIONS[@]}"; do
    target="$skill_dir/$c"
    if [ ! -L "$target" ] || [ "$(readlink "$target")" != "$REPO_ROOT/$c" ]; then
      printf 'AUDIT_MISSING_COMPANION:%s missing or wrong target\n' "$target" >&2
      errors=$((errors + 1))
    fi
  done

  for link in "$skill_dir"/*; do
    [ -L "$link" ] || continue
    target=$(readlink "$link")
    case "$target" in
      "$REPO_ROOT"/*) : ;;
      *) continue ;;
    esac
    if [ ! -e "$target" ]; then
      printf 'AUDIT_DANGLING:%s -> %s (canonical missing)\n' "$link" "$target" >&2
      errors=$((errors + 1))
    fi
  done

  printf '%d\n' "$errors"
}

inject_routing_instructions() {
  local host="$1"
  local instructions_path
  instructions_path=$(yq -r ".\"$host\".global_instructions_path // \"\"" "$REGISTRY" 2>/dev/null)
  [ -z "$instructions_path" ] || [ "$instructions_path" = "null" ] && return 0
  instructions_path="${instructions_path/#\~/$HOME}"
  [ -f "$ROUTING_SOURCE" ] || return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] would inject routing instructions into %s\n' "$instructions_path"
    return 0
  fi

  local marker_start="$ROUTING_MARKER_START"
  local marker_end="$ROUTING_MARKER_END"

  local stripped
  stripped=$(mktemp)
  awk 'NR==1 && /^---$/{s=1;next} s && /^---$/{s=0;next} !s' "$ROUTING_SOURCE" > "$stripped"

  if [ ! -f "$instructions_path" ] || [ ! -s "$instructions_path" ]; then
    local dir
    dir=$(dirname "$instructions_path")
    [ -d "$dir" ] || mkdir -p "$dir"
    { printf '%s\n' "$marker_start"; cat "$stripped"; printf '%s\n' "$marker_end"; } > "$instructions_path"
    rm -f "$stripped"
    printf 'sync-host-skills: created %s with routing instructions\n' "$instructions_path" >&2
    return 0
  fi

  if grep -qF "$marker_start" "$instructions_path"; then
    local tmp
    tmp=$(mktemp)
    awk -v start="$marker_start" -v end="$marker_end" -v src="$stripped" '
      $0 == start { print; while ((getline line < src) > 0) print line; skip=1; next }
      $0 == end   { skip=0; print; next }
      !skip { print }
    ' "$instructions_path" > "$tmp"
    mv "$tmp" "$instructions_path"
    printf 'sync-host-skills: updated routing instructions in %s\n' "$instructions_path" >&2
  else
    { printf '\n%s\n' "$marker_start"; cat "$stripped"; printf '%s\n' "$marker_end"; } >> "$instructions_path"
    printf 'sync-host-skills: appended routing instructions to %s\n' "$instructions_path" >&2
  fi
  rm -f "$stripped"
}

sync_one_host() {
  local host="$1"
  if ! yq -r 'keys | .[]' "$REGISTRY" 2>/dev/null | grep -Fxq "$host"; then
    printf 'sync-host-skills: host "%s" not in hosts/registry.yaml\n' "$host" >&2
    return 2
  fi
  local skill_dir
  skill_dir=$(resolve_skill_dir "$host") || {
    printf 'sync-host-skills: host "%s" has no global_skill_dir\n' "$host" >&2
    return 2
  }

  printf 'sync-host-skills: host=%s skill_dir=%s%s\n' \
    "$host" "$skill_dir" "$([ "$DRY_RUN" -eq 1 ] && printf ' (dry-run)' || true)" >&2

  local project_skill_dir
  project_skill_dir=$(resolve_project_skill_dir "$host" || true)

  if [ "$AUDIT_ONLY" -eq 0 ]; then
    ensure_dir "$skill_dir"
    # Companions first — skills reference _shared/ and scripts/ in their prose.
    # Companions are always global-scoped.
    for c in "${COMPANIONS[@]}"; do
      ensure_link "$REPO_ROOT/$c" "$skill_dir/$c" || true
    done
    # Skills, by portability declaration. Scope determines target dir:
    #   global  → host's global_skill_dir
    #   project → repo's <project_skill_dir>; skipped if canonical IS that path
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      if ! skill_declares_host "$rel" "$host"; then continue; fi
      local name="${rel##*/}"
      local scope
      scope=$(skill_scope "$rel")
      if [ "$scope" = "project" ]; then
        [ -z "$project_skill_dir" ] && continue
        ensure_dir "$project_skill_dir"
        local dst="$project_skill_dir/$name"
        # If canonical already lives at this path, no link needed.
        [ "$REPO_ROOT/$rel" = "$dst" ] && continue
        ensure_link "$REPO_ROOT/$rel" "$dst" || true
      else
        ensure_link "$REPO_ROOT/$rel" "$skill_dir/$name" || true
      fi
    done < <(candidate_roots)
    # Reap stale symlinks left from prior fan-outs.
    remove_stale "$host" "$skill_dir" "global"
    [ -n "$project_skill_dir" ] && [ -d "$project_skill_dir" ] && \
      remove_stale "$host" "$project_skill_dir" "project"
  fi

  # Final audit (always runs, including under --dry-run).
  local audit_errors
  audit_errors=$(audit_host "$host" "$skill_dir")
  if [ "$audit_errors" -gt 0 ]; then
    printf 'sync-host-skills: %d audit issue(s) for host=%s\n' "$audit_errors" "$host" >&2
    return 1
  fi
  if [ "$AUDIT_ONLY" -eq 0 ]; then
    inject_routing_instructions "$host"
  fi

  printf 'sync-host-skills: host=%s OK\n' "$host" >&2
  return 0
}

host_binary_installed() {
  local host="$1" bin
  bin=$(yq -r ".\"$host\".detect_binary // \"\"" "$REGISTRY" 2>/dev/null)
  [ -z "$bin" ] && return 0          # no detect_binary → assume present
  command -v "$bin" >/dev/null 2>&1
}

if [ "$ALL" -eq 1 ]; then
  rc=0
  while IFS= read -r h; do
    [ -z "$h" ] && continue
    if ! host_binary_installed "$h"; then
      printf 'sync-host-skills: host=%s skipped (binary not found on PATH)\n' "$h" >&2
      continue
    fi
    sync_one_host "$h" || rc=$?
  done < <(yq -r 'keys | .[]' "$REGISTRY")
  exit "$rc"
else
  sync_one_host "$HOST"
fi
