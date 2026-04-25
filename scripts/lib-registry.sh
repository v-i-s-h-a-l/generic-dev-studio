#!/usr/bin/env bash
# lib-registry.sh — tool registry engine for the studio wizard.
#
# Reads scripts/tools.yaml (the declarative tool registry) with a built-in
# awk parser — no yq dependency. Provides scan, render, and install
# workflows for three UX modes: quick, auto, interactive.
#
# Depends on: lib-ui.sh (for output/prompt functions, ANSI variables).
# Source lib-ui.sh BEFORE sourcing this file.
#
# Public API:
#
#   registry_load [path]
#       Parse tools.yaml into memory. Call once at startup.
#       Default path: $SCRIPT_DIR/tools.yaml (sibling of this file).
#
#   registry_get <tool-id> <field>
#       Print the value of a field for a tool. Returns "" if not found.
#
#   registry_ids
#       Print all tool IDs, one per line, in declaration order.
#
#   registry_ids_for_role <role> [worker_roles_csv]
#       Print tool IDs relevant to the given role, respecting conditional_on.
#
#   registry_scan <role> [worker_roles_csv]
#       Check presence/version of all relevant tools. Populates:
#         _SCAN_SATISFIED  — "id:version id:version ..."
#         _SCAN_NEEDED     — "id:tier id:tier ..."   (missing required/recommended)
#         _SCAN_OPTIONAL   — "id id ..."             (missing optional)
#         _SCAN_CUSTOM     — "id id ..."             (need custom install flow)
#
#   registry_render_scan <mode>
#       Render scan results. Modes: quick | auto | interactive.
#
#   registry_install_needed <mode>
#       Install tools from _SCAN_NEEDED based on mode.
#       Skips install_type=custom|manual|system (caller handles those).
#       Returns 0 if all required installs succeeded.
#
#   registry_tool_card <tool-id>
#       Render a detailed info card for a single tool.
#
# Scan results are populated as space-separated strings (not arrays) for
# bash 3.2 compatibility. Iterate with: for entry in $VAR; do ... done

[ "${_LIB_REGISTRY_LOADED:-}" = "1" ] && return 0
_LIB_REGISTRY_LOADED=1

# Verify lib-ui.sh is loaded (we need its output functions).
if ! type ok >/dev/null 2>&1; then
  printf 'lib-registry.sh: lib-ui.sh must be sourced first\n' >&2
  return 1
fi

# ============================================================================
# Internal state
# ============================================================================

_REG_CACHE=""
_REG_LOADED=0

_SCAN_SATISFIED=""
_SCAN_NEEDED=""
_SCAN_OPTIONAL=""
_SCAN_CUSTOM=""

# Brew formula cache — populated once per scan when brew is available.
_BREW_FORMULA_CACHE=""

# ============================================================================
# YAML parser — pure awk, handles our flat schema
# ============================================================================
# Output: tab-separated lines: tool_id\tfield_name\tvalue
# Arrays [a, b, c] become space-separated: "a b c"
# Quoted strings have quotes stripped.

_registry_parse() {
  awk '
  BEGIN { id = "" }
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  /^schema:/ || /^tools:/ { next }
  /^[[:space:]]*-[[:space:]]+id:[[:space:]]*/ {
    line = $0
    sub(/^[[:space:]]*-[[:space:]]+id:[[:space:]]*/, "", line)
    gsub(/[[:space:]]*$/, "", line)
    gsub(/"/, "", line)
    id = line
    print id "\tid\t" id
    next
  }
  id != "" && /^[[:space:]]+[a-z_]+:[[:space:]]/ {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    key = line
    sub(/:.*/, "", key)
    val = line
    sub(/^[a-z_]+:[[:space:]]*/, "", val)
    gsub(/[[:space:]]*$/, "", val)
    if (val ~ /^".*"$/) val = substr(val, 2, length(val) - 2)
    if (val ~ /^\[.*\]$/) {
      gsub(/[\[\]]/, "", val)
      gsub(/,[[:space:]]*/, " ", val)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
    }
    if (id != "" && key != "") print id "\t" key "\t" val
  }
  ' "$1"
}

# ============================================================================
# Load
# ============================================================================

registry_load() {
  local yaml="${1:-}"
  if [ -z "$yaml" ]; then
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    yaml="$dir/tools.yaml"
  fi
  if [ ! -f "$yaml" ]; then
    err "tools.yaml not found: $yaml"
    return 1
  fi
  _REG_CACHE=$(_registry_parse "$yaml")
  _REG_LOADED=1
}

# ============================================================================
# Lookup
# ============================================================================

registry_get() {
  local id="$1" field="$2"
  printf '%s\n' "$_REG_CACHE" | awk -F'\t' -v i="$id" -v f="$field" \
    '$1==i && $2==f { print $3; exit }'
}

registry_ids() {
  printf '%s\n' "$_REG_CACHE" | awk -F'\t' '$2=="id" { print $3 }'
}

registry_ids_for_role() {
  local role="$1" wroles="${2:-}"
  local id roles cond req
  for id in $(registry_ids); do
    roles=$(registry_get "$id" "roles")
    case " $roles " in
      *" $role "*) ;;
      *) continue ;;
    esac
    cond=$(registry_get "$id" "conditional_on")
    if [ -n "$cond" ]; then
      case "$cond" in
        worker_role:*)
          req="${cond#worker_role:}"
          case ",$wroles," in *,"$req",*) ;; *) continue ;; esac
          ;;
      esac
    fi
    printf '%s\n' "$id"
  done
}

# ============================================================================
# Scan — check presence + version for all relevant tools
# ============================================================================

registry_scan() {
  local role="$1" wroles="${2:-}"
  _SCAN_SATISFIED="" _SCAN_NEEDED="" _SCAN_OPTIONAL="" _SCAN_CUSTOM=""

  # Cache brew formula list once (avoids ~2-5s per-package dead air).
  _BREW_FORMULA_CACHE=""
  if command -v brew >/dev/null 2>&1; then
    _BREW_FORMULA_CACHE=$(brew list --versions --formula 2>/dev/null || true)
  fi

  local id tier check_type check_target check_fallback check_eval
  local install_type present version

  for id in $(registry_ids_for_role "$role" "$wroles"); do
    tier=$(registry_get "$id" "tier")
    check_type=$(registry_get "$id" "check_type")
    check_target=$(registry_get "$id" "check_target")
    install_type=$(registry_get "$id" "install_type")

    present=0
    version=""

    case "$check_type" in
      command)
        if command -v "$check_target" >/dev/null 2>&1; then
          present=1
        else
          check_fallback=$(registry_get "$id" "check_fallback")
          for _fb_path in $check_fallback; do
            if [ -x "$_fb_path" ]; then present=1; break; fi
          done
        fi
        ;;
      command_or_path)
        if command -v "$check_target" >/dev/null 2>&1; then
          present=1
        else
          check_fallback=$(registry_get "$id" "check_fallback")
          for _fb_path in $check_fallback; do
            if [ -e "$_fb_path" ]; then present=1; break; fi
          done
        fi
        ;;
      path)
        [ -e "$check_target" ] && present=1
        ;;
      eval)
        check_eval=$(registry_get "$id" "check_eval")
        if [ -n "$check_eval" ] && eval "$check_eval" 2>/dev/null; then
          present=1
        fi
        ;;
    esac

    # For brew-installable tools, cross-check against the brew formula cache.
    # This catches tools installed via brew that aren't on PATH yet.
    if [ "$present" = "0" ] && [ -n "$_BREW_FORMULA_CACHE" ]; then
      local _inst_target
      _inst_target=$(registry_get "$id" "install_target")
      if [ -n "$_inst_target" ]; then
        local _pkg_line
        _pkg_line=$(printf '%s\n' "$_BREW_FORMULA_CACHE" | awk -v p="$_inst_target" '$1==p{print; exit}')
        if [ -n "$_pkg_line" ]; then
          present=1
          version=$(printf '%s\n' "$_pkg_line" | awk '{print $NF}')
        fi
      fi
    fi

    if [ "$present" = "1" ]; then
      # Get version if not already from brew cache
      if [ -z "$version" ]; then
        local vcmd
        vcmd=$(registry_get "$id" "version_cmd")
        if [ -n "$vcmd" ]; then
          version=$(eval "$vcmd" 2>/dev/null || true)
        fi
        [ -z "$version" ] && version="installed"
      fi
      # Sanitize: replace spaces with underscores so the space-separated
      # scan results format doesn't break on multi-word version strings.
      version=$(printf '%s' "$version" | tr ' ' '_')
      _SCAN_SATISFIED="$_SCAN_SATISFIED $id:$version"
    else
      # Separate custom-install from brew-installable
      case "$install_type" in
        custom|manual|system)
          _SCAN_CUSTOM="$_SCAN_CUSTOM $id"
          ;;
        *)
          case "$tier" in
            optional) _SCAN_OPTIONAL="$_SCAN_OPTIONAL $id" ;;
            *)        _SCAN_NEEDED="$_SCAN_NEEDED $id:$tier" ;;
          esac
          ;;
      esac
    fi
  done

  # Trim leading spaces
  _SCAN_SATISFIED="${_SCAN_SATISFIED# }"
  _SCAN_NEEDED="${_SCAN_NEEDED# }"
  _SCAN_OPTIONAL="${_SCAN_OPTIONAL# }"
  _SCAN_CUSTOM="${_SCAN_CUSTOM# }"
}

# ============================================================================
# Render — display scan results for the chosen UX mode
# ============================================================================

registry_render_scan() {
  local mode="${1:-auto}"
  local count_sat=0 count_need=0 count_opt=0 count_custom=0
  local entry

  for entry in $_SCAN_SATISFIED; do count_sat=$((count_sat + 1)); done
  for entry in $_SCAN_NEEDED; do count_need=$((count_need + 1)); done
  for entry in $_SCAN_OPTIONAL; do count_opt=$((count_opt + 1)); done
  for entry in $_SCAN_CUSTOM; do count_custom=$((count_custom + 1)); done

  case "$mode" in
    # ------------------------------------------------------------------
    # Quick: minimal — just what's happening
    # ------------------------------------------------------------------
    quick)
      [ "$count_sat" -gt 0 ] && ok "$count_sat tool(s) already satisfied"
      if [ "$count_need" -gt 0 ]; then
        local names=""
        for entry in $_SCAN_NEEDED; do
          local _id="${entry%%:*}"
          names="${names:+$names, }$(registry_get "$_id" "name")"
        done
        info "$count_need tool(s) to install: $names"
      fi
      if [ "$count_custom" -gt 0 ]; then
        local cnames=""
        for entry in $_SCAN_CUSTOM; do
          cnames="${cnames:+$cnames, }$(registry_get "$entry" "name")"
        done
        dim "$count_custom tool(s) with custom install: $cnames"
      fi
      ;;

    # ------------------------------------------------------------------
    # Auto: satisfied = brief list; needed = name + tier + why; optional = noted
    # ------------------------------------------------------------------
    auto)
      if [ "$count_sat" -gt 0 ]; then
        echo
        dim "Already satisfied:"
        for entry in $_SCAN_SATISFIED; do
          local _id="${entry%%:*}" _ver="${entry#*:}"
          printf '    %s✓%s %-20s %s(%s)%s\n' \
            "$c_green" "$c_reset" "$(registry_get "$_id" "name")" "$c_dim" "$_ver" "$c_reset"
        done
      fi

      if [ "$count_need" -gt 0 ]; then
        echo
        dim "To install:"
        for entry in $_SCAN_NEEDED; do
          local _id="${entry%%:*}" _tier="${entry#*:}"
          local _name _why _badge
          _name=$(registry_get "$_id" "name")
          _why=$(registry_get "$_id" "why")
          _badge=$(badge_for_tier "$_tier")
          printf '    %s→%s %-20s %s — %s\n' "$c_blue" "$c_reset" "$_name" "$_badge" "$_why"
        done
      fi

      if [ "$count_opt" -gt 0 ]; then
        echo
        dim "Available (optional — skipped in auto-pilot):"
        for entry in $_SCAN_OPTIONAL; do
          local _name _why
          _name=$(registry_get "$entry" "name")
          _why=$(registry_get "$entry" "why")
          printf '    %s⊘%s %-20s — %s\n' "$c_dim" "$c_reset" "$_name" "$_why"
        done
      fi

      if [ "$count_custom" -gt 0 ]; then
        echo
        dim "Handled in later steps:"
        for entry in $_SCAN_CUSTOM; do
          local _name _why
          _name=$(registry_get "$entry" "name")
          _why=$(registry_get "$entry" "why")
          printf '    %s▹%s %-20s — %s\n' "$c_dim" "$c_reset" "$_name" "$_why"
        done
      fi

      echo
      info "$count_sat satisfied · $count_need to install · $count_opt optional · $count_custom later steps"
      ;;

    # ------------------------------------------------------------------
    # Interactive: full detail, per-tool prompts happen in install phase
    # ------------------------------------------------------------------
    interactive)
      if [ "$count_sat" -gt 0 ]; then
        echo
        printf '  %s── Already satisfied ───────────────────────────────────────%s\n' "$c_dim" "$c_reset"
        for entry in $_SCAN_SATISFIED; do
          local _id="${entry%%:*}" _ver="${entry#*:}"
          local _name _why
          _name=$(registry_get "$_id" "name")
          _why=$(registry_get "$_id" "why")
          printf '    %s✓%s %-20s %s(%s)%s  %s%s%s\n' \
            "$c_green" "$c_reset" "$_name" "$c_dim" "$_ver" "$c_reset" \
            "$c_dim" "$_why" "$c_reset"
        done
      fi

      if [ "$count_need" -gt 0 ]; then
        echo
        printf '  %s── Needs install ────────────────────────────────────────────%s\n' "$c_yellow" "$c_reset"
        for entry in $_SCAN_NEEDED; do
          local _id="${entry%%:*}" _tier="${entry#*:}"
          local _name _why _badge
          _name=$(registry_get "$_id" "name")
          _why=$(registry_get "$_id" "why")
          _badge=$(badge_for_tier "$_tier")
          printf '    %s→%s %s %s — %s\n' "$c_blue" "$c_reset" "$_name" "$_badge" "$_why"
        done
      fi

      if [ "$count_opt" -gt 0 ]; then
        echo
        printf '  %s── Optional ─────────────────────────────────────────────────%s\n' "$c_dim" "$c_reset"
        for entry in $_SCAN_OPTIONAL; do
          local _name _why
          _name=$(registry_get "$entry" "name")
          _why=$(registry_get "$entry" "why")
          printf '    %s⊘%s %-20s — %s\n' "$c_dim" "$c_reset" "$_name" "$_why"
        done
      fi

      if [ "$count_custom" -gt 0 ]; then
        echo
        printf '  %s── Handled in later steps ──────────────────────────────────%s\n' "$c_dim" "$c_reset"
        for entry in $_SCAN_CUSTOM; do
          local _name _why
          _name=$(registry_get "$entry" "name")
          _why=$(registry_get "$entry" "why")
          printf '    %s▹%s %-20s — %s\n' "$c_dim" "$c_reset" "$_name" "$_why"
        done
      fi

      echo
      info "$count_sat satisfied · $count_need to install · $count_opt optional · $count_custom later steps"
      ;;
  esac
}

# ============================================================================
# Install — brew-installable tools based on mode
# ============================================================================

registry_install_needed() {
  local mode="${1:-auto}" failures=0
  local entry id tier

  for entry in $_SCAN_NEEDED; do
    id="${entry%%:*}"; tier="${entry#*:}"

    case "$mode" in
      quick)
        [ "$tier" != "required" ] && continue
        _registry_do_install "$id" || failures=$((failures + 1))
        ;;
      auto)
        _registry_do_install "$id" || failures=$((failures + 1))
        ;;
      interactive)
        _registry_interactive_install "$id" "$tier" || true
        ;;
    esac
  done

  # In interactive mode, also offer optional tools
  if [ "$mode" = "interactive" ] && [ -n "$_SCAN_OPTIONAL" ]; then
    echo
    for id in $_SCAN_OPTIONAL; do
      _registry_interactive_install "$id" "optional" || true
    done
  fi

  return "$failures"
}

# ---- Internal: execute a brew install ----
_registry_do_install() {
  local id="$1"
  local name install_type install_target install_tap
  name=$(registry_get "$id" "name")
  install_type=$(registry_get "$id" "install_type")
  install_target=$(registry_get "$id" "install_target")

  case "$install_type" in
    brew)
      announce "brew install $install_target"
      if run brew install "$install_target"; then
        ok "$name installed"
        return 0
      else
        warn "$name install failed"
        return 1
      fi
      ;;
    brew-cask)
      announce "brew install --cask $install_target"
      if run brew install --cask "$install_target"; then
        ok "$name installed"
        return 0
      else
        warn "$name install failed"
        return 1
      fi
      ;;
    brew-tap)
      install_tap=$(registry_get "$id" "install_tap")
      if [ -n "$install_tap" ]; then
        if ! brew tap 2>/dev/null | grep -Fxq "$install_tap"; then
          announce "brew tap $install_tap"
          run brew tap "$install_tap" >/dev/null 2>&1 || {
            warn "tap $install_tap failed — skipping $name"
            return 1
          }
        fi
      fi
      announce "brew install $install_target"
      if run brew install "$install_target" >/dev/null 2>&1; then
        ok "$name installed"
        return 0
      else
        warn "$name install failed (optional — features that depend on it will fall back)"
        return 1
      fi
      ;;
    *)
      dim "skipping $name — requires custom install (handled elsewhere)"
      return 0
      ;;
  esac
}

# ---- Internal: interactive per-tool prompt with WHY + details ----
_registry_interactive_install() {
  local id="$1" tier="$2"
  local name why details duration alternatives install_type
  name=$(registry_get "$id" "name")
  why=$(registry_get "$id" "why")
  details=$(registry_get "$id" "details")
  duration=$(registry_get "$id" "duration")
  alternatives=$(registry_get "$id" "alternatives")
  install_type=$(registry_get "$id" "install_type")

  # Skip custom/manual installs — caller handles those
  case "$install_type" in custom|manual|system) return 0 ;; esac

  echo
  local badge
  badge=$(badge_for_tier "$tier")
  printf '    %s · %s%s%s\n' "$badge" "$c_bold" "$name" "$c_reset"
  printf '    %s\n' "$why"
  [ -n "$duration" ] && printf '    %sInstall time: %s%s\n' "$c_dim" "$duration" "$c_reset"
  [ -n "$alternatives" ] && printf '    %sAlternative: %s%s\n' "$c_dim" "$alternatives" "$c_reset"

  local default _ofd _ifd reply
  case "$tier" in
    required|recommended) default="y" ;;
    optional)             default="n" ;;
  esac
  _ofd=$(_ui_out_fd); _ifd=$(_ui_in_fd)

  printf '\n    %s⌨%s  Install %s? [%s / ? for details]: ' \
    "$c_yellow" "$c_reset" "$name" \
    "$([ "$default" = "y" ] && printf 'Y/n' || printf 'y/N')" >&"$_ofd"
  IFS= read -r reply <&"$_ifd" || reply=""
  reply="${reply:-$default}"

  # Show details if requested, then re-prompt
  case "$reply" in
    "?"|d|D|details)
      echo
      printf '    %s' "$c_dim"
      # Expand \n in details to actual newlines
      printf '%s\n' "$details" | while IFS= read -r _dline; do
        printf '    %s\n' "$_dline"
      done
      printf '%s' "$c_reset"
      echo
      printf '    %s⌨%s  Install %s? [%s]: ' \
        "$c_yellow" "$c_reset" "$name" \
        "$([ "$default" = "y" ] && printf 'Y/n' || printf 'y/N')" >&"$_ofd"
      IFS= read -r reply <&"$_ifd" || reply=""
      reply="${reply:-$default}"
      ;;
  esac

  case "$reply" in
    y|Y|yes|Yes)
      _registry_do_install "$id"
      ;;
    *)
      case "$tier" in
        required) warn "Skipped $name — some studio features will not work without it" ;;
        *)        dim "Skipped $name" ;;
      esac
      return 1
      ;;
  esac
}

# ============================================================================
# Tool card — detailed info display for configure.sh guide
# ============================================================================

registry_tool_card() {
  local id="$1"
  local name tier why details duration alternatives category
  name=$(registry_get "$id" "name")
  tier=$(registry_get "$id" "tier")
  why=$(registry_get "$id" "why")
  details=$(registry_get "$id" "details")
  duration=$(registry_get "$id" "duration")
  alternatives=$(registry_get "$id" "alternatives")
  category=$(registry_get "$id" "category")

  local badge
  badge=$(badge_for_tier "$tier")

  echo
  printf '  %s%s%s  %s\n' "$c_bold" "$name" "$c_reset" "$badge"
  printf '  %sCategory: %s%s\n' "$c_dim" "$category" "$c_reset"
  echo
  printf '  %s\n' "$why"
  echo
  printf '  %s' "$c_dim"
  printf '%s\n' "$details" | while IFS= read -r _dline; do
    printf '  %s\n' "$_dline"
  done
  printf '%s' "$c_reset"
  [ -n "$duration" ] && printf '\n  %sInstall time: %s%s\n' "$c_dim" "$duration" "$c_reset"
  [ -n "$alternatives" ] && printf '  %sAlternative: %s%s\n' "$c_dim" "$alternatives" "$c_reset"
  echo
}

# ============================================================================
# Utility — check if a specific tool from the registry is installed
# ============================================================================

registry_is_installed() {
  local id="$1"
  case " $_SCAN_SATISFIED " in
    *" $id:"*) return 0 ;;
  esac
  return 1
}

registry_installed_version() {
  local id="$1" entry
  for entry in $_SCAN_SATISFIED; do
    case "$entry" in
      "$id:"*) printf '%s' "${entry#*:}"; return 0 ;;
    esac
  done
  return 1
}
