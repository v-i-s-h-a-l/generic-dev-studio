#!/usr/bin/env bash
# lint-host-agnostic.sh — enforce host-agnostic adapter invariants.
#
# Four checks:
#   1. Claude-Code-specific prose in load-bearing paths (core/v2 roles/reviewer, _shared/)
#   2. Per-host template forks must be symlinks, not regular files
#   3. Capability-manifest security floor (sandbox_profile + secret_scope rules)
#   4. Zero third-party runtime deps in worker paths
#
# Usage:
#   scripts/lint-host-agnostic.sh            # standalone: check 1 is WARN only
#   scripts/lint-host-agnostic.sh --staged   # pre-commit: all checks are BLOCK
#
# Exit 0: pass (warnings on stderr allowed). Exit 1: any BLOCK violation.
# Error format: <CODE>:<file>[:<line>]:<detail>
#
# Note on check 1 severity: pre-sweep state (before H7) has known prose in
# historical worker payloads. In standalone mode, prose hits are WARNs so the
# tree stays green during migrations. In --staged mode, they are BLOCKs
# so new violations don't slip in via future commits.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REGISTRY="$REPO_ROOT/hosts/registry.yaml"

# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

STAGED=0
[ "${1:-}" = "--staged" ] && STAGED=1

ERRORS=0
WARNINGS=0

emit_error() { printf '%s\n' "$1"; ERRORS=$((ERRORS + 1)); }
emit_warn()  { printf '%s\n' "$1" >&2; WARNINGS=$((WARNINGS + 1)); }

# Emit check-1 finding at the appropriate severity.
emit_prose_hit() {
  if [ "$STAGED" -eq 1 ]; then
    emit_error "$1"
  else
    emit_warn "$1"
  fi
}

# -----------------------------------------------------------------------
# Check 1 — Claude-Code-specific prose in load-bearing paths
# Flags tool-name dialect and hook references that would break portability.
# -----------------------------------------------------------------------
check_prose_portability() {
  local patterns=(
    "Agent tool"
    "Read tool"
    "Write tool"
    "Edit tool"
    "Bash tool"
    "SessionStart hook"
    "subagent primitive"
    "invoke a subagent"
    "CLAUDE_PLUGIN_ROOT"
  )

  local search_paths=()
  [ -d "$REPO_ROOT/core/v2/roles" ] && search_paths+=("$REPO_ROOT/core/v2/roles")
  [ -d "$REPO_ROOT/core/v2/reviewer" ] && search_paths+=("$REPO_ROOT/core/v2/reviewer")
  [ -d "$REPO_ROOT/_shared" ]  && search_paths+=("$REPO_ROOT/_shared")

  [ "${#search_paths[@]}" -eq 0 ] && return 0

  local pat file line_no line_text
  for pat in "${patterns[@]}"; do
    while IFS=: read -r file line_no line_text; do
      [ -z "$file" ] && continue
      # Skip lint script itself, REVIEW.md, and the Authoring Standard
      # (they document the patterns to be avoided).
      case "$file" in
        */lint-host-agnostic.sh|*/REVIEW.md|*/_shared/standards/skill-authoring.md) continue ;;
      esac
      emit_prose_hit "E_CLAUDE_PROSE:${file#"$REPO_ROOT/"}:$line_no:\"$pat\" | replace with host-neutral equivalent or move to a Claude-Code-only adapter overlay"
    done < <(
      grep -rn --include="*.md" --include="*.sh" -F "$pat" "${search_paths[@]}" 2>/dev/null || true
    )
  done
}

# -----------------------------------------------------------------------
# Check 2 — Per-host prompt-template forks must be symlinks
# Any file in .codex/ or .claude-plugin/ that shares a basename with a
# file in the canonical v2 role/reviewer payloads must be a symlink, not a
# regular file (to ensure canonical content is not forked).
# -----------------------------------------------------------------------
check_no_template_forks() {
  local host_dirs=()
  while IFS= read -r _h; do
    [ -n "$_h" ] || continue
    local _d
    _d=$(resolve_capabilities_dir "$_h" "$REPO_ROOT" 2>/dev/null) || continue
    _d="${_d#"$REPO_ROOT/"}"
    host_dirs+=("$_d")
  done < <(yq -r 'keys | .[]' "$REGISTRY" 2>/dev/null)
  local canonical_dirs=("core/v2/roles" "core/v2/reviewer")
  local host_dir canonical_dir basename host_file
  for host_dir in "${host_dirs[@]+"${host_dirs[@]}"}"; do
    [ -d "$REPO_ROOT/$host_dir" ] || continue
    for canonical_dir in "${canonical_dirs[@]}"; do
      [ -d "$REPO_ROOT/$canonical_dir" ] || continue
      while IFS= read -r canonical_file; do
        [ -f "$canonical_file" ] || continue
        basename=$(basename "$canonical_file")
        host_file="$REPO_ROOT/$host_dir/$basename"
        if [ -e "$host_file" ] && [ ! -L "$host_file" ]; then
          emit_error "E_TEMPLATE_FORK:$host_dir/$basename | must be a symlink to canonical $canonical_dir/**, not a regular file"
        fi
      done < <(find "$REPO_ROOT/$canonical_dir" -type f \( -name '*.md' -o -name '*.yaml' \) 2>/dev/null)
    done
  done
}

# -----------------------------------------------------------------------
# Check 3 — Capability-manifest security floor
# Parses capabilities.yaml for each non-reference-host adapter.
# Claude Code (.claude-plugin/) is the reference host and is exempt.
# -----------------------------------------------------------------------
# Extract a field value from a simple key: value YAML file.
yaml_field() {
  local file="$1" key="$2"
  grep -E "^${key}:[[:space:]]" "$file" 2>/dev/null \
    | head -1 \
    | sed "s/^${key}:[[:space:]]*//" \
    | tr -d '"'"'"
}

check_capability_security_floor() {
  local manifest host_dir sandbox secret
  # LINT_HOST_AGNOSTIC_EXTRA_DIR: optional comma-separated list of additional
  # adapter dirs to scan (used by tests/conformance harness).
  local extra_dirs=()
  if [ -n "${LINT_HOST_AGNOSTIC_EXTRA_DIR:-}" ]; then
    IFS=',' read -r -a extra_dirs <<<"$LINT_HOST_AGNOSTIC_EXTRA_DIR"
  fi
  while IFS= read -r manifest; do
    [ -f "$manifest" ] || continue
    host_dir=$(basename "$(dirname "$manifest")")
    # Claude Code reference host is explicitly exempt (documented in ADAPTER-SPEC.md).
    case "$host_dir" in
      .claude-plugin) continue ;;
    esac

    sandbox=$(yaml_field "$manifest" sandbox_profile)
    secret=$(yaml_field "$manifest" secret_scope)

    # sandbox_profile: none is always a block (no isolation whatsoever).
    if [ "$sandbox" = "none" ]; then
      emit_error "E_SECURITY_FLOOR:$host_dir/capabilities.yaml:sandbox_profile=none | Achilles adapters require workspace-write or full"
    fi

    # secret_scope: inherit-env is always a block for non-reference hosts
    # (exposes API keys and env to untrusted fixture code).
    if [ "$secret" = "inherit-env" ]; then
      emit_error "E_SECURITY_FLOOR:$host_dir/capabilities.yaml:secret_scope=inherit-env | non-reference-host adapters must use cwd-only or none"
    fi

    # secret_scope: cwd-only is safe for Achilles but insufficient for
    # Argus (which must have none). Warn so the adapter author can add
    # a dedicated Argus-specific manifest or run Argus on a none-scoped host.
    if [ "$secret" = "cwd-only" ]; then
      emit_warn "W_ARGUS_SECRET_SCOPE:$host_dir/capabilities.yaml:secret_scope=cwd-only | Argus dispatch on this host requires secret_scope: none; add a dedicated Argus adapter or route Argus to a none-scoped host"
    fi
  done < <(
    # Discover adapter dirs from registry instead of hardcoding paths.
    while IFS= read -r _lh; do
      [ -n "$_lh" ] || continue
      _lm=$(resolve_capabilities_manifest "$_lh" "$REPO_ROOT" 2>/dev/null) || continue
      [ -f "$_lm" ] && printf '%s\n' "$_lm"
    done < <(yq -r 'keys | .[]' "$REGISTRY" 2>/dev/null)
    # Extra dirs from test harness.
    if [ ${#extra_dirs[@]} -gt 0 ]; then
      find "${extra_dirs[@]}" -maxdepth 1 -name 'capabilities.yaml' 2>/dev/null
    fi
  )
}

# -----------------------------------------------------------------------
# Check 4 — Zero third-party runtime deps in worker paths
# Greps for package manager invocations in worker/reviewer role payloads.
# scripts/ is excluded — infrastructure scripts legitimately include install
# instructions in error messages and README prose, which are not runtime deps.
# -----------------------------------------------------------------------
check_no_runtime_deps() {
  local dep_pats=("npm install" "pip install" "brew install" "gem install")
  local search_paths=()
  [ -d "$REPO_ROOT/core/v2/roles" ] && search_paths+=("$REPO_ROOT/core/v2/roles")
  [ -d "$REPO_ROOT/core/v2/reviewer" ] && search_paths+=("$REPO_ROOT/core/v2/reviewer")

  [ "${#search_paths[@]}" -eq 0 ] && return 0

  local pat file line_no line_text
  for pat in "${dep_pats[@]}"; do
    while IFS=: read -r file line_no line_text; do
      [ -z "$file" ] && continue
      # Skip comment lines (# prefix after optional whitespace).
      case "$line_text" in
        *[[:space:]]'#'*) continue ;;  # inline comment — allowed in docs
      esac
      # Skip if the line itself is a comment.
      trimmed=$(printf '%s' "$line_text" | sed 's/^[[:space:]]*//')
      case "$trimmed" in
        '#'*) continue ;;
      esac
      # Skip scripts/README.md (install instructions are exempt).
      case "$file" in
        */scripts/README.md|*/lint-host-agnostic.sh) continue ;;
      esac
      emit_error "E_RUNTIME_DEP:${file#"$REPO_ROOT/"}:$line_no:\"$pat\" | zero runtime deps in worker paths; add an ADR if this dep is intentional"
    done < <(
      grep -rn --include="*.sh" --include="*.md" -F "$pat" "${search_paths[@]}" 2>/dev/null || true
    )
  done
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
check_prose_portability
check_no_template_forks
check_capability_security_floor
check_no_runtime_deps

printf '%d errors, %d warnings\n' "$ERRORS" "$WARNINGS" >&2
[ "$ERRORS" -eq 0 ]
