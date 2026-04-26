#!/usr/bin/env bash
# lint-comms-boundary.sh — enforce the agent comms boundary contract.
#
# Walks _shared/schemas/capability-manifest.json (regenerated as gate 1b
# of the pre-commit pipeline) and validates every mode-pack `writes:`
# declaration against the writer-ownership matrix encoded in
# _shared/primitives/agent-comms-boundary.md.
#
# Six checks (codes match the primitive's lint specification):
#
#   B1 — Authorial writer ownership.    Non-authorial writer of a
#                                       plans/<kind>/ artifact must
#                                       declare the write as a back-ref
#                                       or state transition.
#   B2 — Forbidden creates.             plans/<kind>/<id>.yaml create-
#                                       shaped writes must come from the
#                                       authorial writer.
#   B3 — Lifecycle co-writer scope.     Non-authorial back-ref / state-
#                                       transition writes are valid only
#                                       for agents listed as co-writers
#                                       for that class.
#   B4 — Master-plan dual-write.        Any non-render writer of
#                                       plans/chanakya-master.md is warn
#                                       pre-#245, block post-#245.
#   B5 — Pass-through purity.           Pass-through agents named in the
#                                       primitive must not declare any
#                                       writes against the artifacts
#                                       they pass through.
#   B6 — Schema reference.              Every plans/<kind>/ write line
#                                       carries a `schema:` annotation
#                                       (warn).
#
# Usage:
#   scripts/lint-comms-boundary.sh            # standalone
#   scripts/lint-comms-boundary.sh --staged   # pre-commit (strict mode)
#
# Exit 0: pass (warnings on stderr allowed). Exit 1: any block-tier hit.
# Error format: <CODE>:<file>[:<location>]:<detail>
#
# Pre-flight: requires jq (already a hard dep in the studio per
# _shared/contracts/EVOLUTION.md §Validator tool — `check-jsonschema`).
#
# When the boundary primitive's matrix changes, update the
# `authorial_for_class`, `co_writer_allowed`, and `pass_through_*`
# functions below in lock-step. The primitive is authoritative for WHY;
# this script is authoritative for HOW.

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/_shared/schemas/capability-manifest.json"

STAGED=0
[ "${1:-}" = "--staged" ] && STAGED=1

# Optional fixture override — drives the synthetic-violation test fixture.
# When set, lints the named manifest file instead of the canonical one.
[ -n "${LINT_BOUNDARY_MANIFEST:-}" ] && MANIFEST="$LINT_BOUNDARY_MANIFEST"

ERRORS=0
WARNINGS=0
emit_error() { printf '%s\n' "$1"; ERRORS=$((ERRORS + 1)); }
emit_warn()  { printf '%s\n' "$1" >&2; WARNINGS=$((WARNINGS + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  printf 'lint-comms-boundary: jq is required\n' >&2
  exit 1
fi

if [ ! -f "$MANIFEST" ]; then
  printf 'lint-comms-boundary: manifest not found at %s\n' "$MANIFEST" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Boundary matrix — encoded from _shared/primitives/agent-comms-boundary.md
# Update both files together when the matrix changes.
# ----------------------------------------------------------------------

# Authorial writer for each plans/<kind>/ class.
authorial_for_class() {
  case "$1" in
    briefs)   printf 'chanakya' ;;
    debriefs) printf 'achilles' ;;
    reviews)  printf 'argus' ;;
    tasks)    printf 'chanakya' ;;
    releases) printf 'achilles' ;;
    *)        printf '' ;;
  esac
}

# Lifecycle co-writers — non-authorial agents permitted append-only / state-
# machine writes against the named class. Returns 'allowed' if permitted.
co_writer_allowed() {
  case "$1:$2" in
    briefs:achilles)   printf 'allowed' ;;  # state: dispatched → debriefed per brief-lifecycle
    debriefs:chanakya) printf 'allowed' ;;  # state: emitted → ingested → superseded
    tasks:achilles)    printf 'allowed' ;;  # back-refs (links.debrief, links.release) + state transitions
    tasks:argus)       printf 'allowed' ;;  # back-ref: links.reviews append (per REVIEW.md R17)
    releases:chanakya) printf 'allowed' ;;  # state transitions on debrief ingest (inbox-sweep)
    *)                 printf '' ;;
  esac
}

# Map class name (plural per primitive matrix) → canonical schema file
# (singular per _shared/schemas/ convention). Used for B6 hint strings.
schema_file_for_class() {
  case "$1" in
    briefs)   printf 'brief' ;;
    debriefs) printf 'debrief' ;;
    reviews)  printf 'review' ;;
    tasks)    printf 'task' ;;
    releases) printf 'release' ;;
    *)        printf '' ;;
  esac
}

# Pass-through agents — must declare zero writes against the listed class.
# Format key: "<agent>:<mode>:<class>".
is_pass_through_agent_mode() {
  case "$1:$2" in
    argus:spec-compliance) printf 'reviews briefs debriefs tasks' ;;
    achilles:worker)       printf '' ;;  # not a pass-through for any plans class
    chanakya:status)       printf 'tasks releases reviews' ;;
    *)                     printf '' ;;
  esac
}

# Render-master-plan writer is the lone post-#245 writer of class 5
# (master-plan). Other writers are warn-tier today.
RENDER_WRITER='render-master-plan.sh'

# B3 — annotation phrases that mark a write line as a legitimate
# co-writer surface. Substring match against the write declaration's
# inline comment (everything after the `#`).
LIFECYCLE_MARKERS=(
  'back-ref'
  'state transition'
  'state bumps'
  'state mut'
  'state-machine'
  'task-lifecycle'
  'brief-lifecycle'
  'release-lifecycle'
  'debrief-lifecycle'
  'feedback-lifecycle'
  'links.'
  'state archive'
  'archive eligibility'
  'state transitions to archived'
  'emitted → ingested'
  '→ ingested'
  'state transitions per'
  'archived'
  'rebuild-index.sh'   # idempotent index regen — not a payload mutation
  'legacy debrief move'
  'legacy debrief markdown'
  'legacy markdown debrief'
  'legacy master-plan'
  'legacy active'
  'legacy archive'
  'legacy staging'
  'archival sink'
  'legacy mutation'
  'legacy: Slack'
  'release state'
  'mid-flight'
  'regenerated'
  'legacy: '
)

# Path → class membership.
class_for_path() {
  local p="$1"
  case "$p" in
    *plans/briefs/*)        printf 'briefs' ;;
    *plans/debriefs/*)      printf 'debriefs' ;;
    *plans/reviews/*)       printf 'reviews' ;;
    *plans/tasks/*)         printf 'tasks' ;;
    *plans/releases/*)      printf 'releases' ;;
    *plans/chanakya-master.md*) printf 'master-plan' ;;
    *)                      printf '' ;;
  esac
}

# Plain-text test for "this declaration looks like a mutate, not a create".
# Returns 'mutate' if any LIFECYCLE_MARKER substring is present.
declaration_is_mutate() {
  local decl="$1" marker
  for marker in "${LIFECYCLE_MARKERS[@]}"; do
    case "$decl" in
      *"$marker"*) printf 'mutate'; return 0 ;;
    esac
  done
  printf ''
}

# Plain-text test for "this declaration carries a schema: annotation"
# (B6). Returns 'has' if so.
declaration_has_schema() {
  case "$1" in
    *schema:*) printf 'has' ;;
    *)         printf '' ;;
  esac
}

# ----------------------------------------------------------------------
# Walk the manifest. One row per write declaration.
#
# jq output format (TSV):
#   <agent>\t<mode>\t<write-string>
# where <write-string> is the entire declared write line including any
# inline `# annotation` text.
# ----------------------------------------------------------------------

walk_manifest() {
  jq -r '
    .agents[]
    | . as $agent
    | .modes[]?
    | . as $mode
    | (.writes // [])[]
    | [$agent.name, $mode.name, .]
    | @tsv
  ' "$MANIFEST"
}

# ----------------------------------------------------------------------
# Per-row checks
# ----------------------------------------------------------------------

check_row() {
  local agent="$1" mode="$2" write_decl="$3"
  local class authorial source_loc
  source_loc="capability-manifest.json:$agent/$mode"

  class=$(class_for_path "$write_decl")
  [ -z "$class" ] && return 0   # not a comms-boundary surface; skip

  # B5 — pass-through purity. If this agent/mode is registered as a
  # pass-through for the class, declaring any write against it is a block.
  local pt_classes
  pt_classes=$(is_pass_through_agent_mode "$agent" "$mode")
  if [ -n "$pt_classes" ]; then
    case " $pt_classes " in
      *" $class "*)
        emit_error "B_PASS_THROUGH_VIOLATION:$source_loc:class=$class | pass-through ($agent/$mode) must not declare writes against $class artifacts (see _shared/primitives/agent-comms-boundary.md §Pass-through agents)"
        return 0
        ;;
    esac
  fi

  # B4 — master-plan dual-write. Block-tier post-#245 A.4/A.5 (the legacy
  # mutating writers in lib-ledger.sh are retired; the only legitimate writer
  # of plans/chanakya-master.md is render-master-plan.sh).
  if [ "$class" = "master-plan" ]; then
    case "$write_decl" in
      *"$RENDER_WRITER"*) return 0 ;;
    esac
    emit_error "B_MASTER_PLAN_DUAL_WRITE:$source_loc:class=$class | $agent/$mode writes plans/chanakya-master.md — only $RENDER_WRITER may write the rendered projection (see _shared/primitives/agent-comms-boundary.md §B4 and #245 A.4/A.5)"
    return 0
  fi

  # Compute mutate-vs-create classification once — used by B6 and B1/B2/B3.
  local is_mutate co_writer
  is_mutate=$(declaration_is_mutate "$write_decl")

  # B6 — schema reference. Warn only on CREATE-shaped lines (mutations
  # carry no payload, so a schema reference is not meaningful). Inferred-
  # only paths (legacy markdown fallbacks) are exempt.
  if [ -z "$is_mutate" ] && [ -z "$(declaration_has_schema "$write_decl")" ]; then
    case "$write_decl" in
      *legacy*) : ;;
      *)
        local schema_file
        schema_file=$(schema_file_for_class "$class")
        emit_warn "W_MISSING_SCHEMA_REF:$source_loc:class=$class | create-shaped write lacks schema: annotation (add e.g. 'schema: _shared/schemas/${schema_file}.md')"
        ;;
    esac
  fi

  # B1 / B2 / B3 — writer ownership.
  authorial=$(authorial_for_class "$class")
  if [ -z "$authorial" ]; then
    return 0   # unrecognised class; defensive
  fi

  if [ "$agent" = "$authorial" ]; then
    return 0   # authorial writer is always allowed
  fi

  # Non-authorial writer. Two questions:
  #   (a) Is this a mutate-shaped declaration? (B1)
  #   (b) Is this agent enumerated as a co-writer for this class? (B3)
  co_writer=$(co_writer_allowed "$class" "$agent")

  if [ -z "$is_mutate" ]; then
    # Looks like a create. Block per B2.
    emit_error "B_FORBIDDEN_CREATE:$source_loc:class=$class | $agent/$mode declares a create-shaped write against plans/$class/ but the authorial writer is $authorial (per _shared/primitives/agent-comms-boundary.md). Add a back-ref / state-transition annotation if this is a co-writer surface, or remove the declaration."
    return 0
  fi

  # Mutate-shaped. Verify the agent is an enumerated co-writer.
  if [ -z "$co_writer" ]; then
    emit_error "B_LIFECYCLE_OUT_OF_SCOPE:$source_loc:class=$class | $agent is not an enumerated lifecycle co-writer for $class artifacts (per _shared/primitives/agent-comms-boundary.md §The six message classes). Either add the agent to the matrix and update this script, or remove the declaration."
    return 0
  fi

  # B1 satisfied — non-authorial mutate by an enumerated co-writer.
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

# When --staged: only run if a relevant file is staged. The boundary lint
# is sensitive to changes in:
#   - any modes/*.md (frontmatter reads/writes)
#   - capability-manifest.json (regenerated by gate 1b)
#   - the boundary primitive itself (matrix changes)
#   - this script (matrix encoding changes)
if [ "$STAGED" -eq 1 ]; then
  staged_relevant=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null \
    | grep -E '(modes/.*\.md|capability-manifest\.json|agent-comms-boundary\.md|lint-comms-boundary\.sh)$' \
    || true)
  if [ -z "$staged_relevant" ]; then
    exit 0
  fi
fi

while IFS=$'\t' read -r agent mode write_decl; do
  [ -z "$agent" ] && continue
  check_row "$agent" "$mode" "$write_decl"
done < <(walk_manifest)

printf 'lint-comms-boundary: %d errors, %d warnings\n' "$ERRORS" "$WARNINGS" >&2
[ "$ERRORS" -eq 0 ]
