#!/usr/bin/env bash
# studio-audit.sh — arc-coherence probes for planning quality.
#
# Runs cheap checks against ROADMAP.md, the project's memory store, git history,
# and the studio GitHub Project state. Silent when clean. Emits structured +
# human output on drift.
#
# Probes:
#   A1  Decision-ledger consistency — phases marked ✓ in ROADMAP must be
#       referenced by a memory file, and memory pickup files must line up
#       with the ROADMAP's "Completed" vs "Planned" split.
#   A2  Claim-evidence audit — every phase in "Completed" must cite evidence
#       (a commit, tag, or issue) somewhere in ROADMAP, or be backed by a
#       matching release tag / merged PR.
#   A3  Arc-exit checklist — for arcs marked CLOSED in memory, the closure
#       must be consistent: parking-lot empty (no studio-consolidation/
#       parking-lot.md with open items), no project_*_pending.md left
#       unanswered, release tagged if the arc crossed a release threshold.
#   A4  PM-surface Project state — current v2 parent arcs must be present on
#       the Studio v2 transition Project with Status, Track, Phase, Size, and
#       Sibling host reviewed fields populated.
#
# Usage:
#   scripts/studio-audit.sh              # human + summary, exit 0 on clean, 1 on drift
#   scripts/studio-audit.sh --silent     # only emit output if drift exists
#   scripts/studio-audit.sh --json       # machine-readable summary (for hooks)
#   scripts/studio-audit.sh --report     # write full report to ~/.dev-studio/<proj>/audit/<date>.md
#
# Probes are grep/JQ/GitHub-CLI only, no LLM round-trips. A4 is the only remote
# probe and reads Projects v2 through scripts/studio-project-state.sh.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=./lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

MODE=human
for arg in "$@"; do
  case "$arg" in
    --silent) MODE=silent ;;
    --json)   MODE=json ;;
    --report) MODE=report ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0
      ;;
  esac
done

ROADMAP="$REPO_ROOT/ROADMAP.md"
PROJ_HASH=$(printf '%s' "$REPO_ROOT" | tr '/.' '-')
MEM_DIR="$HOME/.claude-personal/projects/$PROJ_HASH/memory"

drift_count=0
report=""

add_finding() {
  local probe="$1" severity="$2" msg="$3"
  drift_count=$((drift_count + 1))
  report="${report}[$severity] $probe: $msg"$'\n'
}

# ──────────────────────────────────────────────────────────────────────────────
# A1 — Decision-ledger consistency
# Flag: phases in ROADMAP "Completed" that no memory file references.
# Flag: memory pickup notes claiming CLOSED that ROADMAP shows as Planned.
# ──────────────────────────────────────────────────────────────────────────────

probe_a1() {
  [ -f "$ROADMAP" ] || { add_finding A1 warn "ROADMAP.md missing at $ROADMAP"; return; }
  [ -d "$MEM_DIR" ] || return  # no memory yet = no ledger to cross-check

  # If memory mentions a multi-phase arc (e.g., consolidation arc), treat all
  # sub-phases under that arc's ROADMAP entry as covered.
  local arc_covered=0
  if grep -qliE 'consolidation arc|arc CLOSED|Sessions? [A-F]' "$MEM_DIR"/*.md 2>/dev/null; then
    arc_covered=1
  fi

  local completed
  completed=$(awk '
    /^### Completed/ {flag=1; next}
    /^### / && flag {flag=0}
    flag && /✓/ {print}
  ' "$ROADMAP" | grep -oE 'Phase [0-9]+(\.[0-9]+)*' | sort -u)

  local mem_refs
  mem_refs=$(grep -rohE 'Phase [0-9]+(\.[0-9]+)*' "$MEM_DIR" 2>/dev/null | sort -u)

  while IFS= read -r phase; do
    [ -z "$phase" ] && continue
    if ! printf '%s\n' "$mem_refs" | grep -qxF "$phase"; then
      # If an arc-level memory entry exists, sub-phases (2.6, 2.6.5, 2.6.6) are covered by it.
      [ $arc_covered -eq 1 ] && continue
      add_finding A1 warn "$phase marked ✓ in ROADMAP but no memory file references it (or an arc covering it)"
    fi
  done <<< "$completed"
}

# ──────────────────────────────────────────────────────────────────────────────
# A2 — Claim-evidence audit
# Every phase in "Completed" must cite at least one of:
#   - a release tag (v0.X.Y) reachable via `git tag`
#   - a commit range / PR / issue reference in the ROADMAP text for that phase
# ──────────────────────────────────────────────────────────────────────────────

probe_a2() {
  [ -f "$ROADMAP" ] || return
  local in_completed=0 current_phase="" current_block=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^###\ Completed ]]; then in_completed=1; continue; fi
    if [[ "$line" =~ ^###\  ]] && [ $in_completed -eq 1 ]; then
      # End of previous phase entry — evaluate
      if [ -n "$current_phase" ]; then eval_phase_block "$current_phase" "$current_block"; fi
      in_completed=0
      current_phase=""; current_block=""
      continue
    fi
    [ $in_completed -eq 1 ] || continue
    if [[ "$line" =~ Phase\ [0-9]+ ]] && [[ "$line" =~ ✓ ]]; then
      local new_phase
      new_phase=$(printf '%s\n' "$line" | grep -oE 'Phase [0-9]+(\.[0-9]+)*' | head -1)
      if [ "$new_phase" = "$current_phase" ]; then
        # Same phase number, multi-entry (e.g., "Phase 2" + "Phase 2 (snap)") — concat
        current_block="$current_block"$'\n'"$line"
      else
        if [ -n "$current_phase" ]; then eval_phase_block "$current_phase" "$current_block"; fi
        current_phase="$new_phase"
        current_block="$line"
      fi
    else
      current_block="$current_block"$'\n'"$line"
    fi
  done < "$ROADMAP"
  # Flush final block
  [ -n "$current_phase" ] && [ $in_completed -eq 1 ] && eval_phase_block "$current_phase" "$current_block"
}

eval_phase_block() {
  local phase="$1" block="$2"
  # Evidence classes (any one suffices):
  #   - commit/issue/tag: #NNN, vX.Y.Z, SHA-like hex, "closes", "landed", "ships"
  #   - file-path citations: backtick-quoted paths, .md/.sh/.yaml/.json extensions,
  #     or known top-level dirs (_shared/, scripts/, .claude/, chanakya/, achilles/, argus/)
  #   - quantitative metrics: "N lines", "N modes", "N packs", "N fixtures"
  if printf '%s' "$block" | grep -qE '#[0-9]+|v[0-9]+\.[0-9]+\.[0-9]+|[a-f0-9]{7,}|closes |landed |ships |migrated|backfill|published|release-'; then
    return
  fi
  if printf '%s' "$block" | grep -qE '`[^`]*\.(md|sh|yaml|yml|json)|\.(md|sh|yaml|yml|json)`|(_shared|scripts|\.claude|chanakya|achilles|argus|studio)/'; then
    return
  fi
  if printf '%s' "$block" | grep -qE '[0-9]+[[:space:]]+(line|mode|pack|fixture|commit|event)'; then
    return
  fi
  add_finding A2 warn "$phase marked ✓ without citeable evidence (no commit/tag/issue/path/metric)"
}

# ──────────────────────────────────────────────────────────────────────────────
# A3 — Arc-exit checklist
# For each memory file whose name or content contains CLOSED, check:
#   - studio-consolidation/parking-lot.md does not exist, or is empty of open items
#   - no project_*_pending.md files remain with unanswered questions
# ──────────────────────────────────────────────────────────────────────────────

probe_a3() {
  [ -d "$MEM_DIR" ] || return
  local closed_mentions
  closed_mentions=$(grep -lE 'CLOSED|arc (closed|done)' "$MEM_DIR"/*.md 2>/dev/null || true)
  [ -z "$closed_mentions" ] && return

  # Parking-lot check — count bullets OUTSIDE Rules/Format/Header sections.
  # Bullets under "## Rules", "## Format", etc. are meta-instructions, not parked items.
  local parking="$REPO_ROOT/studio-consolidation/parking-lot.md"
  if [ -f "$parking" ]; then
    local open_items
    open_items=$(awk '
      /^## / {
        in_meta = (tolower($0) ~ /rules|format|convention|how to|header/) ? 1 : 0
        next
      }
      !in_meta && /^[*-] / {count++}
      END {print count+0}
    ' "$parking")
    if [ "$open_items" -gt 0 ]; then
      add_finding A3 warn "Arc(s) marked CLOSED but studio-consolidation/parking-lot.md has $open_items open item(s)"
    fi
  fi

  # Pending questions check
  local pendings
  pendings=$(ls "$MEM_DIR"/project_*_pending.md 2>/dev/null || true)
  if [ -n "$pendings" ]; then
    add_finding A3 warn "Arc(s) marked CLOSED but memory still has project_*_pending.md files: $(echo $pendings | xargs -n1 basename | tr '\n' ' ')"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# A4 — PM-surface Project state
# Current v2 parent arcs should be readable from GitHub Projects v2 with the
# fields agents need for backlog flows.
# ──────────────────────────────────────────────────────────────────────────────

probe_a4() {
  local reader="$SCRIPT_DIR/studio-project-state.sh"
  [ -x "$reader" ] || { add_finding A4 warn "scripts/studio-project-state.sh missing or not executable"; return; }

  local state_json
  state_json=$("$reader" --json --limit 200 2>/dev/null) || {
    add_finding A4 warn "GitHub Project state unreadable via scripts/studio-project-state.sh"
    return
  }

  local issue missing missing_fields
  for issue in 443 444 445 446; do
    missing=$(printf '%s\n' "$state_json" | jq -r --argjson issue "$issue" '
      any(.[]; .issue_number == $issue) | not
    ')
    if [ "$missing" = true ]; then
      add_finding A4 warn "#$issue missing from Studio v2 transition Project state"
      continue
    fi

    missing_fields=$(printf '%s\n' "$state_json" | jq -r --argjson issue "$issue" '
      .[] | select(.issue_number == $issue)
      | [
          (if (.status // "") == "" then "Status" else empty end),
          (if (.track // "") == "" then "Track" else empty end),
          (if (.phase // "") == "" then "Phase" else empty end),
          (if (.size // "") == "" then "Size" else empty end),
          (if (.sibling_host_reviewed // "") == "" then "Sibling host reviewed" else empty end)
        ]
      | join(", ")
    ')
    [ -n "$missing_fields" ] && add_finding A4 warn "#$issue Project item missing field(s): $missing_fields"
  done
}

probe_a1
probe_a2
probe_a3
probe_a4

# ──────────────────────────────────────────────────────────────────────────────
# Output
# ──────────────────────────────────────────────────────────────────────────────

emit_json() {
  printf '{"status":"%s","drift":%d,"probes":["A1","A2","A3","A4"]}\n' \
    "$([ $drift_count -eq 0 ] && echo ok || echo drift)" "$drift_count"
}

emit_human() {
  if [ $drift_count -eq 0 ]; then
    printf 'studio-audit: clean. 4 probes ran, 0 drift.\n'
    return
  fi
  printf 'studio-audit: %d drift item(s).\n\n%s' "$drift_count" "$report"
}

case "$MODE" in
  silent) [ $drift_count -gt 0 ] && emit_human ;;
  json)   emit_json ;;
  report)
    audit_root=$(resolve_audit_root) || {
      printf 'resolve_audit_root failed — cannot write report\n' >&2
      exit 2
    }
    date_stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
    dst="$audit_root/$date_stamp.md"
    mkdir -p "$(dirname "$dst")"
    {
      printf '# studio-audit report — %s\n\n' "$date_stamp"
      printf 'Repo: `%s`\n\n' "$REPO_ROOT"
      printf 'Drift items: **%d**\n\n' "$drift_count"
      if [ $drift_count -eq 0 ]; then printf 'No drift detected.\n'; else printf '## Findings\n\n```\n%s```\n' "$report"; fi
    } > "$dst"
    printf '%s\n' "$dst"
    ;;
  human) emit_human ;;
esac

[ $drift_count -eq 0 ] && exit 0 || exit 1
