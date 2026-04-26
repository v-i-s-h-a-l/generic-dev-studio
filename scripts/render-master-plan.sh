#!/usr/bin/env bash
# render-master-plan.sh — Stage A.0 / #273
#
# Shape B projector. Reads YAML sources + an optional editorial preamble and
# writes plans/chanakya-master.md deterministically. The legacy markdown surface
# survives Commit H (#245 Stage A) as a render-only projection — consumers like
# scripts/sweep-threshold-actions.sh keep working while the source-of-truth
# moves under plans/{tasks,releases,build-debt}.yaml.
#
# Sources (all optional — projector emits a sensible empty section when absent):
#   plans/master-plan-preamble.md  — verbatim editorial prose (Dashboard,
#                                    Module Index, Argus-Skipped Merges,
#                                    Blocked-on-External-Input). Owned by
#                                    /chanakya compact + manual edits.
#   plans/build-debt.yaml          — Build Debt section. Schema:
#                                    _shared/schemas/build-debt.md.
#   plans/index.yaml               — Active Tasks ordering (from .tasks[].id).
#   plans/tasks/<uuid>.yaml        — per-task body. Uses .legacy_row when
#                                    present; falls back to a minimal stub.
#   plans/releases/<uuid>.yaml     — Release Log rows. One row per file.
#
# Output:
#   plans/chanakya-master.md       — atomic write (tmp + rename). Never edited
#                                    in place.
#
# Idempotency: same inputs → byte-identical output. Safe to run from sweep-
# ingest's end-of-run hook on every sweep.
#
# Exit codes:
#   0  rendered ok (or no-op when there is genuinely nothing to render)
#   2  fatal — missing dependency (yq), unresolvable project, write failed

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"
# shellcheck source=lib-ledger.sh
. "$SCRIPT_DIR/lib-ledger.sh"

PROJECT=$(resolve_project 2>/dev/null) || {
  printf 'render-master-plan: no project context (cwd outside any tracked repo)\n' >&2
  exit 0
}
PROJECT_ROOT=$(resolve_project_root_for "$PROJECT")
PLANS_DIR="$PROJECT_ROOT/plans"
TASKS_DIR="$PLANS_DIR/tasks"
RELEASES_DIR="$PLANS_DIR/releases"
INDEX_YAML="$PLANS_DIR/index.yaml"
PREAMBLE_MD="$PLANS_DIR/master-plan-preamble.md"
BUILD_DEBT_YAML="$PLANS_DIR/build-debt.yaml"
OUT="$PLANS_DIR/chanakya-master.md"

[ -d "$PLANS_DIR" ] || { printf 'render-master-plan: no plans/ dir at %s\n' "$PLANS_DIR" >&2; exit 0; }

if ! command -v yq >/dev/null 2>&1; then
  printf 'render-master-plan: yq required but not installed\n' >&2
  exit 2
fi

# Safeguard: refuse to overwrite a populated master-plan unless the editorial
# preamble has been extracted. A master-plan that exists *without* a preamble
# is a signal that this project has never been bootstrapped — the original file
# carries hand-curated content (Dashboard, Module Index, etc.) that lives
# nowhere else. Run scripts/extract-master-plan-preamble.sh first to extract
# the preamble + build-debt.yaml, then re-run the projector.
#
# Set RENDER_MASTER_PLAN_FORCE=1 to override (e.g. for tests against synthetic
# fixtures with no editorial content to preserve).
if [ "${RENDER_MASTER_PLAN_FORCE:-0}" != "1" ] \
   && [ -f "$OUT" ] && [ ! -f "$PREAMBLE_MD" ]; then
  printf 'render-master-plan: refusing to overwrite %s — no preamble at %s.\n' "$OUT" "$PREAMBLE_MD" >&2
  printf '  Run scripts/extract-master-plan-preamble.sh first to extract the editorial preamble + build-debt.yaml.\n' >&2
  printf '  Override with RENDER_MASTER_PLAN_FORCE=1 (only safe when there is no editorial content to preserve).\n' >&2
  exit 2
fi

DISPLAY_NAME=$(resolve_display_name 2>/dev/null || printf '%s' "$PROJECT")
RENDER_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

TMP=$(mktemp "${OUT}.tmp.XXXXXX") || { printf 'render-master-plan: mktemp failed\n' >&2; exit 2; }
trap 'rm -f "$TMP"' EXIT

# ---------- Header ----------

{
  printf '# %s — Master Plan\n' "$DISPLAY_NAME"
  printf '**Updated:** %s (rendered by `scripts/render-master-plan.sh` from `plans/{tasks,releases,build-debt}.yaml` + `master-plan-preamble.md`)\n' "$RENDER_TS"
  printf '\n---\n\n'
} > "$TMP"

# ---------- Editorial preamble (verbatim include) ----------
#
# The preamble holds Dashboard / Module Index / Argus-Skipped / Blocked-on-
# External-Input — content that has no YAML home today. Owned by /chanakya
# compact + manual edits. Bootstrap from existing master-plan via
# scripts/extract-master-plan-preamble.sh.

if [ -f "$PREAMBLE_MD" ]; then
  cat "$PREAMBLE_MD" >> "$TMP"
  # Ensure trailing newline before the next programmatic section.
  printf '\n' >> "$TMP"
fi

# ---------- Build Debt section ----------

render_build_debt() {
  if [ ! -f "$BUILD_DEBT_YAML" ]; then
    printf '## Build Debt\n\n_No build-debt YAML yet — bootstrap with `scripts/extract-master-plan-preamble.sh` or wait for first build-check ingest._\n\n'
    return 0
  fi
  local counter state warn_at block_at last_green last_sha unverified broken open_check blocked_by next_n notes
  counter=$(yq -r '.counter // 0' "$BUILD_DEBT_YAML" 2>/dev/null)
  state=$(yq -r '.state // "silent"' "$BUILD_DEBT_YAML" 2>/dev/null)
  warn_at=$(yq -r '.warn_at // 6' "$BUILD_DEBT_YAML" 2>/dev/null)
  block_at=$(yq -r '.block_at // 12' "$BUILD_DEBT_YAML" 2>/dev/null)
  last_green=$(yq -r '.last_green // ""' "$BUILD_DEBT_YAML" 2>/dev/null)
  last_sha=$(yq -r '.last_green_sha // ""' "$BUILD_DEBT_YAML" 2>/dev/null)
  unverified=$(yq -r '.unverified_since // [] | join(", ")' "$BUILD_DEBT_YAML" 2>/dev/null)
  broken=$(yq -r '.broken_commit_sha // ""' "$BUILD_DEBT_YAML" 2>/dev/null)
  open_check=$(yq -r '.open_check_task // ""' "$BUILD_DEBT_YAML" 2>/dev/null)
  blocked_by=$(yq -r '.blocked_by // ""' "$BUILD_DEBT_YAML" 2>/dev/null)
  next_n=$(yq -r '.next_tbuild_n // 1' "$BUILD_DEBT_YAML" 2>/dev/null)
  notes=$(yq -r '.notes // ""' "$BUILD_DEBT_YAML" 2>/dev/null)

  printf '## Build Debt\n\n'
  printf -- '- Counter: %s / warn@%s / block@%s\n' "$counter" "$warn_at" "$block_at"
  printf -- '- State: %s\n' "$state"
  printf -- '- Last green: %s\n' "${last_green:-—}"
  printf -- '- Last green SHA: %s\n' "${last_sha:-—}"
  printf -- '- Unverified since: [%s]\n' "${unverified}"
  [ -n "$broken" ] && [ "$broken" != "null" ] && printf -- '- Broken commit: %s\n' "$broken"
  printf -- '- Open check task: %s\n' "${open_check:-—}"
  printf -- '- Blocked by: %s\n' "${blocked_by:-—}"
  printf -- '- Next TBUILD n: %s\n' "$next_n"
  [ -n "$notes" ] && [ "$notes" != "null" ] && { printf '\n'; printf '%s\n' "$notes"; }
  printf '\n<!-- Source of truth: plans/build-debt.yaml. Edits here will be overwritten on the next sweep. -->\n\n'
}

render_build_debt >> "$TMP"

# ---------- Active Tasks ----------
#
# Walk plans/tasks/*.yaml, ordered by legacy_task_id (numeric within letter
# group). Tasks lacking a legacy_task_id appear last, sorted by uuid.
# Per task: emit `### <legacy_id> — <title>` then the legacy_row body. When
# legacy_row is absent, emit a minimal stub from task fields.

render_active_tasks() {
  printf '## Active Tasks\n\n'
  if [ ! -d "$TASKS_DIR" ]; then
    printf '_No tasks YAML directory — fresh project._\n\n'
    return 0
  fi

  # Build sortable key per task: <sort-class>\t<sort-numeric>\t<legacy_id>\t<file>
  # sort-class: 0=has legacy_task_id, 1=uuid-only.
  # sort-numeric: digits inside legacy_task_id (zero-padded), or 0.
  local sort_input
  sort_input=$(mktemp "${TMPDIR:-/tmp}/render-mp-sort-XXXXXX") || return 2
  local f legacy_id sort_num
  for f in "$TASKS_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    legacy_id=$(yq -r '.legacy_task_id // ""' "$f" 2>/dev/null)
    if [ -n "$legacy_id" ] && [ "$legacy_id" != "null" ]; then
      # Extract digits for natural ordering (T9 < T10). Suffix letters preserve
      # T218a/T218b ordering by string compare on the trailing tail.
      sort_num=$(printf '%s' "$legacy_id" | tr -cd '0-9')
      [ -z "$sort_num" ] && sort_num=0
      # Strip leading zeros so printf doesn't read the value as octal.
      sort_num=$((10#$sort_num))
      printf '0\t%010d\t%s\t%s\n' "$sort_num" "$legacy_id" "$f" >> "$sort_input"
    else
      printf '1\t0000000000\t%s\t%s\n' "$(basename "$f" .yaml)" "$f" >> "$sort_input"
    fi
  done

  if [ ! -s "$sort_input" ]; then
    rm -f "$sort_input"
    printf '_No tasks yet._\n\n'
    return 0
  fi

  # Sort: class asc, numeric asc, legacy_id asc.
  local sorted
  sorted=$(sort -t '	' -k1,1n -k2,2n -k3,3 "$sort_input")
  rm -f "$sort_input"

  local title legacy_row state release_uuid release_label
  while IFS=$'\t' read -r _class _num display_id f; do
    [ -f "$f" ] || continue
    title=$(yq -r '.title // ""' "$f" 2>/dev/null)
    legacy_row=$(yq -r '.legacy_row // ""' "$f" 2>/dev/null)
    state=$(yq -r '.state // "unknown"' "$f" 2>/dev/null)
    release_uuid=$(yq -r '.links.release // ""' "$f" 2>/dev/null)

    printf '### %s — %s\n' "$display_id" "$title"

    if [ -n "$release_uuid" ] && [ "$release_uuid" != "null" ]; then
      release_label=$(_release_label_for_uuid "$release_uuid")
      [ -n "$release_label" ] && printf -- '- **Released in:** %s\n' "$release_label"
    fi

    if [ -n "$legacy_row" ] && [ "$legacy_row" != "null" ]; then
      printf '%s\n' "$legacy_row"
    else
      printf -- '- **Status:** %s\n' "$state"
    fi
    printf '\n'
  done <<< "$sorted"
}

# Cache release-uuid → label so we don't re-shell yq per task.
RELEASE_LABEL_CACHE=$(mktemp "${TMPDIR:-/tmp}/render-mp-rels-XXXXXX") || exit 2
trap 'rm -f "$TMP" "$RELEASE_LABEL_CACHE"' EXIT

build_release_label_cache() {
  [ -d "$RELEASES_DIR" ] || return 0
  local rf uuid bn ch label
  for rf in "$RELEASES_DIR"/*.yaml; do
    [ -f "$rf" ] || continue
    uuid=$(yq -r '.id // ""' "$rf" 2>/dev/null)
    bn=$(yq -r '.build_number // ""' "$rf" 2>/dev/null)
    ch=$(yq -r '.channel // "testflight"' "$rf" 2>/dev/null)
    [ -z "$uuid" ] && continue
    case "$ch" in
      appstore) label="AS-$bn" ;;
      *)        label="TF-$bn" ;;
    esac
    printf '%s\t%s\n' "$uuid" "$label" >> "$RELEASE_LABEL_CACHE"
  done
}

_release_label_for_uuid() {
  local uuid="${1:-}"
  [ -z "$uuid" ] && return 0
  awk -F '\t' -v u="$uuid" '$1 == u { print $2; exit }' "$RELEASE_LABEL_CACHE" 2>/dev/null
}

build_release_label_cache
render_active_tasks >> "$TMP"

# ---------- Release Log ----------
#
# Renders one row per releases/*.yaml, ordered by build_number ascending.

render_release_log() {
  printf '## Release Log\n\n'
  if [ ! -d "$RELEASES_DIR" ]; then
    printf '_No releases yet._\n\n'
    return 0
  fi
  local any=0
  printf '| Build | Version | Type | Date | Tag | HEAD | Tasks Included |\n'
  printf '|-------|---------|------|------|-----|------|---------------|\n'

  local rows
  rows=$(mktemp "${TMPDIR:-/tmp}/render-mp-rel-XXXXXX") || return 2
  local rf bn ver ch tag head date tasks
  for rf in "$RELEASES_DIR"/*.yaml; do
    [ -f "$rf" ] || continue
    bn=$(yq -r '.build_number // ""' "$rf" 2>/dev/null)
    ver=$(yq -r '.version // ""' "$rf" 2>/dev/null)
    ch=$(yq -r '.channel // "testflight"' "$rf" 2>/dev/null)
    tag=$(yq -r '.tag // ""' "$rf" 2>/dev/null)
    head=$(yq -r '.commit_sha // ""' "$rf" 2>/dev/null)
    date=$(yq -r '.released_at // .submitted_at // ""' "$rf" 2>/dev/null | cut -c1-10)
    # tasks may be a list or a single string — legacy releases were
    # inconsistent. Disambiguate via tag rather than yq's if/elif (mikefarah
    # yq's lexer rejects `if tag == "!!seq"` inline).
    local tasks_tag
    tasks_tag=$(yq -r '.tasks | tag' "$rf" 2>/dev/null)
    case "$tasks_tag" in
      '!!seq') tasks=$(yq -r '.tasks | join(", ")' "$rf" 2>/dev/null) ;;
      '!!str') tasks=$(yq -r '.tasks' "$rf" 2>/dev/null) ;;
      *)       tasks="" ;;
    esac
    [ -z "$bn" ] && continue
    local bn_pad
    bn_pad=$(printf '%010d' $((10#$bn)) 2>/dev/null) || bn_pad="$bn"
    printf '%s\t| %s | %s | %s | %s | %s | %s | %s |\n' \
      "$bn_pad" \
      "$bn" "$ver" "$ch" "$date" "$tag" "$head" "$tasks" >> "$rows"
    any=1
  done

  if [ "$any" = "1" ]; then
    sort -t '	' -k1,1n "$rows" | cut -f2-
  else
    printf '_No releases yet._\n'
  fi
  printf '\n'
  rm -f "$rows"
}

render_release_log >> "$TMP"

# ---------- Atomic publish ----------

mv "$TMP" "$OUT" || { printf 'render-master-plan: rename to %s failed\n' "$OUT" >&2; exit 2; }
trap - EXIT
rm -f "$RELEASE_LABEL_CACHE"

exit 0
