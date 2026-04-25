#!/usr/bin/env bash
# lint-skill-prose.sh — enforce the Skill Authoring Standard.
#
# Validates frontmatter against _shared/standards/skill-frontmatter.json,
# routing.yaml against routing.json, portability.yaml against portability.json,
# and body grammar against the rules in _shared/standards/skill-authoring.md.
#
# Usage:
#   scripts/lint-skill-prose.sh [<file_or_dir> ...]
#       Lint specific files / dirs; if none given, lints every SKILL.md and
#       mode-pack under the repo (achilles/, argus/, chanakya/, .claude/skills/,
#       skills/owned/, skills/vendored/) plus their routing.yaml / portability.yaml.
#
#   scripts/lint-skill-prose.sh --staged
#       Lint only files staged for commit. Exits 0 if no relevant files staged.
#
# Exit 0: pass (warnings on stderr allowed). Exit 1: any block-level violation.
# Error format: <CODE>:<file>[:<line>]:<detail>
#
# Dependencies (frozen at host-agnostic v1, R13):
#   - yq (mikefarah variant)
#   - check-jsonschema (Python; bundled by bootstrap)
# Both are optional fallbacks: if missing, frontmatter parses degrade to
# awk; schema validation skipped with a warning. The grammar checks are
# pure bash/awk and always run.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
STANDARDS_DIR="$REPO_ROOT/_shared/standards"

ERRORS=0
WARNINGS=0

emit_error() { printf '%s\n' "$1"; ERRORS=$((ERRORS + 1)); }
emit_warn()  { printf '%s\n' "$1" >&2; WARNINGS=$((WARNINGS + 1)); }

# -----------------------------------------------------------------------
# File discovery
# -----------------------------------------------------------------------
collect_targets() {
  local mode="$1"; shift
  case "$mode" in
    --staged)
      git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
        | grep -E '(^|/)SKILL\.md$|/modes/[^/]+\.md$|/routing\.yaml$|/portability\.yaml$' \
        || true
      ;;
    --explicit)
      local arg
      for arg in "$@"; do
        if [ -f "$arg" ]; then
          printf '%s\n' "${arg#"$REPO_ROOT/"}"
        elif [ -d "$arg" ]; then
          find "$arg" -type f \
            \( -name 'SKILL.md' -o -name 'routing.yaml' -o -name 'portability.yaml' \
               -o -path '*/modes/*.md' \) 2>/dev/null \
            | while IFS= read -r f; do printf '%s\n' "${f#"$REPO_ROOT/"}"; done
        fi
      done
      ;;
    --all)
      ( cd "$REPO_ROOT" && \
        find achilles argus chanakya .claude/skills skills/owned skills/vendored \
             _shared/standards \
             -type f \
             \( -name 'SKILL.md' -o -name 'routing.yaml' -o -name 'portability.yaml' \
                -o -path '*/modes/*.md' \) 2>/dev/null )
      ;;
  esac
}

# -----------------------------------------------------------------------
# Frontmatter extraction (awk, stdlib-only)
# -----------------------------------------------------------------------
# Prints the YAML frontmatter content (without the --- delimiters) for a
# markdown file. Empty if no frontmatter.
extract_frontmatter() {
  awk '
    BEGIN { in_fm=0 }
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm==1 && $0=="---" { exit }
    in_fm==1 { print }
  ' "$1"
}

# Read a top-level scalar field from the frontmatter. Tries yq first; falls
# back to a key-prefix awk extraction when yq rejects the YAML (common when
# unquoted descriptions contain colons). Returns empty if missing.
fm_field() {
  local file="$1" key="$2" fm out
  fm=$(extract_frontmatter "$file")
  if command -v yq >/dev/null 2>&1; then
    out=$(printf '%s' "$fm" | yq -r ".$key // \"\"" 2>/dev/null)
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  fi
  printf '%s' "$fm" | awk -v key="$key" '
    BEGIN { pat = "^"key":[[:space:]]" }
    $0 ~ pat {
      sub(pat, "", $0)
      sub(/^[[:space:]]+/, "", $0)
      gsub(/^["'\'']|["'\'']$/, "", $0)
      print
      exit
    }
  '
}

# -----------------------------------------------------------------------
# Schema validation (check-jsonschema)
# -----------------------------------------------------------------------
HAVE_JSCHEMA=0
if command -v check-jsonschema >/dev/null 2>&1; then HAVE_JSCHEMA=1; fi

# Filter raw check-jsonschema output to the meaningful diagnostic lines only.
# Drops urllib3/SSL warnings, blank lines, the "Schema validation errors..."
# preamble, and trims the temp-file path prefix from each issue line.
filter_jsonschema_output() {
  awk '
    /Library\/Python|warnings\.warn|NotOpenSSL/ { next }
    /^[[:space:]]*$/ { next }
    /^Schema validation errors/ { next }
    {
      sub(/^[[:space:]]+/, "", $0)
      # Strip any "<temp-path>::" prefix (path → jsonpath separator).
      sub(/^[^:]+::/, "", $0)
      print
    }
  '
}

run_jsonschema() {
  PYTHONWARNINGS=ignore check-jsonschema --schemafile "$1" "$2" 2>&1
}

# -----------------------------------------------------------------------
# Body grammar checks
# -----------------------------------------------------------------------
SOFT_MODALS_RE='\b(should|may|might|consider|perhaps|maybe|try to|if possible|we could|it would be good)\b'
SENTINELS='READ WRITE RUN CHECK EMIT RECORD STOP PROCEED RETRY SKIP ESCALATE BLOCK'

# Required H2 sections for type=skill
REQUIRED_SKILL_HEADINGS=(
  '## What this skill does'
  '## What this skill does not do'
  '## Inputs'
  '## Outputs'
  '## When to invoke'
  '## Procedure'
  '## Failure modes'
)

# Locate H2 block: prints lines that start with the H2 header, up to (but
# not including) the next H2 / H1.
extract_h2_section() {
  local file="$1" heading="$2"
  awk -v h="$heading" '
    BEGIN { in_block=0 }
    $0==h { in_block=1; print; next }
    in_block==1 && /^##[^#]/ { exit }
    in_block==1 && /^# / { exit }
    in_block==1 { print }
  ' "$file"
}

# Soft-modal scan inside the Procedure block of a file. Numbered list lines
# (^\s*\d+\.) and their indented continuation are the regulated region.
check_soft_modals_in_procedure() {
  local file="$1" rel="$2" proc
  proc=$(extract_h2_section "$file" '## Procedure')
  [ -z "$proc" ] && return 0

  local line_no=0
  local heading_line_no=0
  heading_line_no=$(grep -n -F '## Procedure' "$file" | head -1 | cut -d: -f1)
  [ -z "$heading_line_no" ] && heading_line_no=0

  printf '%s\n' "$proc" \
    | awk -v hl="$heading_line_no" -v re="$SOFT_MODALS_RE" -v rel="$rel" '
        BEGIN { IGNORECASE=1 }
        NR==1 { next }  # skip the heading itself
        {
          # Lines we lint: numbered steps + their indented continuation +
          # decision-table cells. Skip blank lines and code fences.
          if ($0 ~ /^[[:space:]]*$/) { fence_open = fence_open; next }
          if ($0 ~ /^```/) { fence_open = !fence_open; next }
          if (fence_open) next
          if (match($0, re)) {
            abs_line = hl + NR - 1
            print "E_SOFT_MODAL_IN_PROCEDURE:" rel ":" abs_line ":" substr($0, RSTART, RLENGTH) " — replace with imperative; soft modals encode optionality, procedures are not optional"
          }
        }
      '
}

# Verify each numbered step in ## Procedure starts with a sentinel verb and
# has Before:/After: lines.
check_step_grammar() {
  local file="$1" rel="$2" proc
  proc=$(extract_h2_section "$file" '## Procedure')
  [ -z "$proc" ] && return 0

  local heading_line_no
  heading_line_no=$(grep -n -F '## Procedure' "$file" | head -1 | cut -d: -f1)
  [ -z "$heading_line_no" ] && heading_line_no=0

  printf '%s\n' "$proc" \
    | awk -v hl="$heading_line_no" -v sentinels="$SENTINELS" -v rel="$rel" '
        BEGIN {
          n = split(sentinels, arr, " ")
          for (i = 1; i <= n; i++) sset[arr[i]] = 1
        }
        function classify(line,    s) {
          # Strip leading "<n>. " and any leading **  /  __ markers.
          sub(/^[[:space:]]*[0-9]+\.[[:space:]]+/, "", line)
          sub(/^\*\*/, "", line); sub(/^__/, "", line)
          # Take the first whitespace-delimited token (strip trailing ** etc.)
          if (match(line, /^[A-Z]+/)) {
            s = substr(line, 1, RLENGTH)
            return s
          }
          return ""
        }
        /^```/ { fence = !fence; next }
        fence { next }
        /^[[:space:]]*[0-9]+\.[[:space:]]+/ {
          # New step header line.
          if (cur_step_line && !(seen_before[cur_step_line] && seen_after[cur_step_line])) {
            # Final flush handled below
          }
          cur_step_line = NR
          first_token = classify($0)
          if (first_token == "") {
            print "E_MISSING_SENTINEL:" rel ":" (hl + NR - 1) ":step does not start with an UPPERCASE sentinel verb (one of: " sentinels ")"
          } else if (!(first_token in sset)) {
            print "E_MISSING_SENTINEL:" rel ":" (hl + NR - 1) ":step starts with non-sentinel verb \"" first_token "\" (allowed: " sentinels ")"
          }
          seen_before[cur_step_line] = 0
          seen_after[cur_step_line] = 0
          next
        }
        cur_step_line && /^[[:space:]]+Before:/  { seen_before[cur_step_line] = 1; next }
        cur_step_line && /^[[:space:]]+After:/   { seen_after[cur_step_line]  = 1; next }
        /^[[:space:]]*$/ {
          # Blank ends a step block; flush if pending.
          if (cur_step_line) {
            if (!seen_before[cur_step_line])
              print "E_MISSING_PRE_POST:" rel ":" (hl + cur_step_line - 1) ":step missing Before: line"
            if (!seen_after[cur_step_line])
              print "E_MISSING_PRE_POST:" rel ":" (hl + cur_step_line - 1) ":step missing After: line"
            cur_step_line = 0
          }
        }
        END {
          if (cur_step_line) {
            if (!seen_before[cur_step_line])
              print "E_MISSING_PRE_POST:" rel ":" (hl + cur_step_line - 1) ":step missing Before: line"
            if (!seen_after[cur_step_line])
              print "E_MISSING_PRE_POST:" rel ":" (hl + cur_step_line - 1) ":step missing After: line"
          }
        }
      '
}

# Verify the Failure modes block has Classification ∈ {transient,permanent,ambiguous}.
check_failure_modes() {
  local file="$1" rel="$2" fm
  fm=$(extract_h2_section "$file" '## Failure modes')
  if [ -z "$fm" ]; then
    emit_error "E_MISSING_FAILURE_MODES:$rel:no \"## Failure modes\" section found"
    return 0
  fi
  # Look for classification cells. Loose: scan each table row for one of the three.
  printf '%s\n' "$fm" | awk -v rel="$rel" '
    /^\|/ && !/^\|[-: ]+\|/ && !/^\|[[:space:]]*Failure[[:space:]]*\|/ {
      n = split($0, cells, "|")
      # cells[1] is empty (leading |); count actual columns.
      if (n < 4) next
      cls = cells[3]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cls)
      if (cls == "" ) next
      if (cls != "transient" && cls != "permanent" && cls != "ambiguous") {
        print "E_BAD_FAILURE_CLASSIFICATION:" rel ":Classification=\"" cls "\" must be one of: transient, permanent, ambiguous"
      }
    }
  '
}

# Required H2s for type=skill.
check_skill_headings() {
  local file="$1" rel="$2" h
  for h in "${REQUIRED_SKILL_HEADINGS[@]}"; do
    if ! grep -q -F -m1 "$h" "$file"; then
      emit_error "E_MISSING_AFFORDANCE_HEADER:$rel:required heading \"$h\" not found"
    fi
  done
}

# -----------------------------------------------------------------------
# Per-file dispatch
# -----------------------------------------------------------------------
lint_skill_md() {
  local file="$1" rel="$2"

  # Vendored skills are exempt by location: anything under skills/vendored/
  # has a sibling vendor.yaml that records the upstream + license + SHA.
  # We trust that record; the upstream's frontmatter shape is the upstream
  # author's call, not ours to police.
  case "$rel" in
    skills/vendored/*) return 0 ;;
  esac

  local fm tmp_fm fm_json type_field exempt name desc desc_len
  fm=$(extract_frontmatter "$file")
  if [ -z "$fm" ]; then
    emit_error "E_MISSING_FRONTMATTER:$rel:no YAML frontmatter found"
    return
  fi

  # Validate frontmatter against JSON Schema (via yq → json | check-jsonschema).
  if [ "$HAVE_JSCHEMA" -eq 1 ] && command -v yq >/dev/null 2>&1; then
    tmp_fm=$(mktemp -t skill-fm.XXXXXX.json)
    local raw_out filtered_out rc
    if printf '%s' "$fm" | yq -o=json '.' >"$tmp_fm" 2>/dev/null; then
      raw_out=$(run_jsonschema "$STANDARDS_DIR/skill-frontmatter.json" "$tmp_fm")
      rc=$?
      if [ "$rc" -ne 0 ]; then
        filtered_out=$(printf '%s\n' "$raw_out" | filter_jsonschema_output)
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          emit_error "E_INVALID_FRONTMATTER:$rel:$line"
        done <<<"$filtered_out"
      fi
    fi
    rm -f "$tmp_fm"
  fi

  type_field=$(fm_field "$file" type)
  exempt=$(fm_field "$file" authoring_standard)
  name=$(fm_field "$file" name)
  desc=$(fm_field "$file" description)

  # When the schema validator is present, the JSON Schema is canonical for
  # required-key and description-length errors — don't duplicate them here.
  # Without it, fall back to native checks so the gate still has teeth.
  if [ "$HAVE_JSCHEMA" -ne 1 ]; then
    if [ -z "$type_field" ]; then
      emit_error "E_MISSING_REQUIRED_KEY:$rel:type field is required"
    fi
    if [ -n "$desc" ]; then
      desc_len=${#desc}
      if [ "$desc_len" -gt 280 ]; then
        emit_error "E_DESCRIPTION_TOO_LONG:$rel:description is $desc_len chars (max 280)"
      fi
    fi
  fi
  if [ -n "$desc" ]; then
    desc_len=${#desc}
    if [ "$desc_len" -le 280 ] && [ "$desc_len" -gt 200 ]; then
      emit_warn "W_LONG_DESCRIPTION:$rel:description is $desc_len chars (>200; consider trimming)"
    fi
  fi

  # Kebab-case is required only for invocation-bearing kinds (skill,
  # agent-router) since they map to `/<name>` slash commands. Mode-packs are
  # internal mode files; their name is a documentation label, so Title Case
  # is allowed.
  case "$type_field" in
    skill|agent-router)
      if [ -n "$name" ] && ! printf '%s' "$name" | grep -qE '^[a-z0-9][a-z0-9._-]*$'; then
        emit_error "E_BAD_NAME:$rel:name=\"$name\" must be kebab-case for type=$type_field (^[a-z0-9][a-z0-9._-]*\$)"
      fi
      ;;
  esac
  case "$type_field" in
    skill)
      local dir_name
      dir_name=$(basename "$(dirname "$file")")
      if [ -n "$name" ] && [ "$name" != "$dir_name" ]; then
        emit_warn "W_NAME_DIR_MISMATCH:$rel:frontmatter name=\"$name\" but dir=\"$dir_name\""
      fi
      ;;
  esac

  # Vendored exempt: skip body grammar.
  if [ "$exempt" = "exempt" ]; then
    return
  fi

  case "$type_field" in
    skill)
      check_skill_headings "$file" "$rel"
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        emit_error "$line"
      done < <(check_soft_modals_in_procedure "$file" "$rel")
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        emit_error "$line"
      done < <(check_step_grammar "$file" "$rel")
      check_failure_modes "$file" "$rel"
      ;;
    mode-pack)
      # Mode packs can be heterogeneous; lint Procedure if present, otherwise skip.
      if grep -q -E '^## Procedure' "$file"; then
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          emit_error "$line"
        done < <(check_soft_modals_in_procedure "$file" "$rel")
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          emit_error "$line"
        done < <(check_step_grammar "$file" "$rel")
      fi
      if grep -q -E '^## Failure modes' "$file"; then
        check_failure_modes "$file" "$rel"
      fi
      ;;
    agent-router|primitive|reference|standard)
      : # frontmatter-only validation already done
      ;;
    *)
      emit_error "E_BAD_TYPE:$rel:type=\"$type_field\" not in {agent-router, mode-pack, skill, primitive, reference, standard}"
      ;;
  esac

  # Sibling routing.yaml / portability.yaml handled by their own dispatch.
}

lint_routing_yaml() {
  local file="$1" rel="$2"
  if [ "$HAVE_JSCHEMA" -ne 1 ] || ! command -v yq >/dev/null 2>&1; then
    emit_warn "W_NO_JSCHEMA:$rel:skipping routing.yaml schema validation (yq + check-jsonschema required)"
    return
  fi
  local tmp_json
  tmp_json=$(mktemp -t routing.XXXXXX.json)
  if ! yq -o=json '.' "$file" >"$tmp_json" 2>/dev/null; then
    emit_error "E_INVALID_ROUTING:$rel:routing.yaml does not parse as YAML"
    rm -f "$tmp_json"; return
  fi
  local raw_out filtered_out rc
  raw_out=$(run_jsonschema "$STANDARDS_DIR/routing.json" "$tmp_json")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    filtered_out=$(printf '%s\n' "$raw_out" | filter_jsonschema_output)
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      emit_error "E_INVALID_ROUTING:$rel:$line"
    done <<<"$filtered_out"
  fi
  rm -f "$tmp_json"
}

lint_portability_yaml() {
  local file="$1" rel="$2"
  if [ "$HAVE_JSCHEMA" -ne 1 ] || ! command -v yq >/dev/null 2>&1; then
    emit_warn "W_NO_JSCHEMA:$rel:skipping portability.yaml schema validation (yq + check-jsonschema required)"
    return
  fi
  local tmp_json
  tmp_json=$(mktemp -t portability.XXXXXX.json)
  if ! yq -o=json '.' "$file" >"$tmp_json" 2>/dev/null; then
    emit_error "E_INVALID_PORTABILITY:$rel:portability.yaml does not parse as YAML"
    rm -f "$tmp_json"; return
  fi
  local raw_out filtered_out rc
  raw_out=$(run_jsonschema "$STANDARDS_DIR/portability.json" "$tmp_json")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    filtered_out=$(printf '%s\n' "$raw_out" | filter_jsonschema_output)
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      emit_error "E_INVALID_PORTABILITY:$rel:$line"
    done <<<"$filtered_out"
  fi
  # Cross-check declared hosts exist in registry.
  local registry="$REPO_ROOT/hosts/registry.yaml"
  if [ -f "$registry" ]; then
    local declared known h
    declared=$(yq -r '.hosts[]' "$file" 2>/dev/null || true)
    known=$(yq -r 'keys | .[]' "$registry" 2>/dev/null || true)
    while IFS= read -r h; do
      [ -z "$h" ] && continue
      if ! printf '%s\n' "$known" | grep -Fxq "$h"; then
        emit_error "E_INVALID_PORTABILITY:$rel:host \"$h\" not declared in hosts/registry.yaml"
      fi
    done <<<"$declared"
  fi
  rm -f "$tmp_json"
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
mode="--all"
if [ "${1:-}" = "--staged" ]; then
  mode="--staged"; shift
elif [ $# -gt 0 ]; then
  mode="--explicit"
fi

targets=$(collect_targets "$mode" "$@")

if [ -z "$targets" ] && [ "$mode" = "--staged" ]; then
  # Nothing relevant staged; no-op pass.
  exit 0
fi

while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  abs="$REPO_ROOT/$rel"
  [ -f "$abs" ] || continue
  case "$rel" in
    *.md)
      lint_skill_md "$abs" "$rel"
      ;;
    */routing.yaml)
      lint_routing_yaml "$abs" "$rel"
      ;;
    */portability.yaml)
      lint_portability_yaml "$abs" "$rel"
      ;;
  esac
done <<<"$targets"

printf '%d errors, %d warnings\n' "$ERRORS" "$WARNINGS" >&2
[ "$ERRORS" -eq 0 ]
