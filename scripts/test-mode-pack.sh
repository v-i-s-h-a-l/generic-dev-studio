#!/usr/bin/env bash
# test-mode-pack.sh — driver for the skill-testing primitive.
#
# Discipline: _shared/primitives/skill-testing.md
# Fixtures:   tests/mode-packs/<agent>/<mode>.yaml
#
# Subcommands:
#   list                         # every mode pack + its fixture status (present/missing)
#   validate [<pack>]            # parse fixtures, check required fields. No subagent spawn.
#   scaffold <agent>/<mode>      # write a fixture skeleton for the named pack
#   run <pack>                   # run one fixture end-to-end (spawns 2 subagents)
#   run-all                      # run every fixture sequentially
#
# Flags:
#   --dry-run                    # valid only with `run`/`run-all`; composes prompts but skips claude -p
#   --model <id>                 # override model for subagent invocations (default: haiku-cheap)
#   --verbose                    # print composed prompts + raw subagent output
#
# Exit codes:
#   0 — all requested fixtures pass
#   1 — fixture failure (regression or broken baseline)
#   2 — fixture validation error (malformed YAML, missing pack, etc.)
#   3 — usage error

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FIXTURE_ROOT="$REPO_ROOT/tests/mode-packs"

DRY_RUN=0
VERBOSE=0
MODEL="${TEST_MODE_PACK_MODEL:-claude-haiku-4-5-20251001}"

die()  { printf 'error: %s\n' "$*" >&2; exit "${2:-3}"; }
log()  { printf '%s\n' "$*" >&2; }
vlog() { [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*" >&2; return 0; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing prerequisite: $1" 3
}

# Enumerate every mode pack in the repo. Mirrors lint-architecture.sh's
# collect_candidates but scoped to modes/*.md (SKILL.md covered separately).
enumerate_packs() {
  find "$REPO_ROOT" -mindepth 3 -maxdepth 3 -type f -path '*/modes/*.md' 2>/dev/null
  find "$REPO_ROOT" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' 2>/dev/null \
    | while IFS= read -r f; do
        # Only agent SKILL.md files count (must have sibling modes/ dir OR be a
        # single-file agent like argus/SKILL.md).
        case "$f" in
          */chanakya/SKILL.md|*/achilles/SKILL.md|*/argus/SKILL.md) printf '%s\n' "$f" ;;
        esac
      done
}

# Given a pack path (repo-relative OR absolute), return the fixture path.
# chanakya/modes/status.md → tests/mode-packs/chanakya/status.yaml
# argus/SKILL.md           → tests/mode-packs/argus/SKILL.yaml
fixture_path_for() {
  local pack="$1" rel agent mode
  rel="${pack#"$REPO_ROOT/"}"
  agent="${rel%%/*}"
  mode=$(basename "$rel" .md)
  printf '%s/%s/%s.yaml\n' "$FIXTURE_ROOT" "$agent" "$mode"
}

# ---------- list ----------
cmd_list() {
  local pack fixture status
  printf '%-50s  %s\n' "PACK" "FIXTURE"
  while IFS= read -r pack; do
    [ -z "$pack" ] && continue
    fixture=$(fixture_path_for "$pack")
    if [ -f "$fixture" ]; then
      status="present"
    else
      status="MISSING ($fixture)"
    fi
    printf '%-50s  %s\n' "${pack#"$REPO_ROOT/"}" "$status"
  done < <(enumerate_packs | sort)
}

# ---------- validate ----------
validate_fixture() {
  local fixture="$1" schema pack_rel pack_abs scenario failure_count success_count
  require yq

  [ -f "$fixture" ] || { log "validate: not found: $fixture"; return 2; }

  schema=$(yq -r '.schema // ""' "$fixture" 2>/dev/null)
  pack_rel=$(yq -r '.pack // ""' "$fixture" 2>/dev/null)
  scenario=$(yq -r '.scenario // ""' "$fixture" 2>/dev/null)
  failure_count=$(yq -r '.failure_signals // [] | length' "$fixture" 2>/dev/null)
  success_count=$(yq -r '.success_signals // [] | length' "$fixture" 2>/dev/null)

  [ "$schema" = "1" ] || { log "validate: $fixture: schema must be 1 (got: '$schema')"; return 2; }
  [ -n "$pack_rel" ]  || { log "validate: $fixture: missing 'pack'"; return 2; }
  [ -n "$scenario" ]  || { log "validate: $fixture: missing 'scenario'"; return 2; }
  [ "$failure_count" -ge 1 ] || { log "validate: $fixture: need >=1 failure_signals"; return 2; }
  [ "$success_count" -ge 1 ] || { log "validate: $fixture: need >=1 success_signals"; return 2; }

  pack_abs="$REPO_ROOT/$pack_rel"
  [ -f "$pack_abs" ] || { log "validate: $fixture: pack not found at $pack_abs"; return 2; }

  vlog "validate: $fixture ok (pack=$pack_rel, failure_sigs=$failure_count, success_sigs=$success_count)"
  return 0
}

cmd_validate() {
  local target="${1:-}" f rc any=0
  if [ -n "$target" ]; then
    f=$(fixture_path_for "$target")
    validate_fixture "$f"
    return $?
  fi
  find "$FIXTURE_ROOT" -type f -name '*.yaml' 2>/dev/null | sort | while IFS= read -r f; do
    if ! validate_fixture "$f"; then
      printf 'FAIL %s\n' "$f"
      any=1
    else
      printf 'OK   %s\n' "$f"
    fi
  done
  # Count failures separately (pipe subshell ate $any; re-derive).
  local fail_count
  fail_count=$(find "$FIXTURE_ROOT" -type f -name '*.yaml' 2>/dev/null | while IFS= read -r f; do
    validate_fixture "$f" >/dev/null 2>&1 || printf '.\n'
  done | wc -l | tr -d ' ')
  [ "$fail_count" -eq 0 ] || return 2
}

# ---------- scaffold ----------
cmd_scaffold() {
  local target="${1:-}" f pack_rel
  [ -n "$target" ] || die "scaffold: need <agent>/<mode> (e.g. chanakya/status)" 3
  # Accept either "chanakya/status" or "chanakya/modes/status.md"
  case "$target" in
    */modes/*) pack_rel="$target" ;;
    */SKILL)   pack_rel="${target%/SKILL}/SKILL.md" ;;
    */*)
      local agent="${target%%/*}" mode="${target#*/}"
      if [ -f "$REPO_ROOT/$agent/modes/${mode}.md" ]; then
        pack_rel="$agent/modes/${mode}.md"
      elif [ -f "$REPO_ROOT/$agent/SKILL.md" ] && [ "$mode" = "SKILL" ]; then
        pack_rel="$agent/SKILL.md"
      else
        die "scaffold: can't resolve pack for '$target'" 3
      fi
      ;;
    *) die "scaffold: need <agent>/<mode>" 3 ;;
  esac

  f=$(fixture_path_for "$REPO_ROOT/$pack_rel")
  [ -f "$f" ] && die "scaffold: fixture already exists: $f" 3
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<EOF
# Skill-testing fixture for $pack_rel
# See _shared/primitives/skill-testing.md for schema + authoring rules.
schema: 1
pack: $pack_rel
scenario: |
  TODO: a concrete task the pack is load-bearing for. NOT "summarize the pack";
  a real job the pack's guidance should shape.
failure_signals:
  # Regexes expected to appear in the WITHOUT-pack run.
  - "TODO"
success_signals:
  # Regexes expected to appear in the WITH-pack run (and absent from WITHOUT).
  - "TODO"
notes: |
  TODO: what regression this catches. Delete if self-evident.
EOF
  printf 'scaffolded: %s\n' "$f"
}

# ---------- run ----------
# Compose the stripped prompt — scenario + explicit denial of the pack.
compose_stripped() {
  local scenario="$1" pack_rel="$2"
  cat <<EOF
$scenario

---

Constraint: you do NOT have access to \`$pack_rel\` or any file it references.
Do not Read them. Reason from first principles and whatever you already know.
EOF
}

# Compose the loaded prompt — pack contents + separator + scenario.
compose_loaded() {
  local pack_abs="$1" scenario="$2"
  cat "$pack_abs"
  printf '\n\n---\n\n%s\n' "$scenario"
}

# Invoke a headless Claude subagent with the given composed prompt. Respects
# --dry-run. Captures stdout. Falls through any non-zero exit from claude -p.
invoke_subagent() {
  local prompt="$1" tag="$2" out rc
  if [ "$DRY_RUN" -eq 1 ]; then
    vlog "[dry-run:$tag] would invoke claude -p (prompt=${#prompt} chars)"
    printf '[dry-run:%s: %d-char prompt]\n' "$tag" "${#prompt}"
    return 0
  fi
  require claude
  vlog "[$tag] invoking claude -p (model=$MODEL)"
  if ! out=$(printf '%s' "$prompt" | claude -p --model "$MODEL" 2>&1); then
    rc=$?
    log "[$tag] claude -p exited $rc"
    printf '%s\n' "$out"
    return "$rc"
  fi
  printf '%s\n' "$out"
}

# Check whether every regex in the given array is present in the output.
# Returns 0 if ALL match, 1 otherwise. Emits per-regex hit/miss to stderr when
# verbose.
signals_all_present() {
  local output="$1" sigs_var="$2" tag="$3"
  # Read signals into a local array (bash 3.2 compatible).
  local sigs sig count=0 missing=0
  # shellcheck disable=SC2034
  eval "sigs=(\"\${${sigs_var}[@]}\")"
  for sig in "${sigs[@]}"; do
    count=$((count + 1))
    if printf '%s' "$output" | grep -qE "$sig"; then
      vlog "[$tag] signal HIT:  $sig"
    else
      vlog "[$tag] signal MISS: $sig"
      missing=$((missing + 1))
    fi
  done
  [ "$missing" -eq 0 ]
}

# Check whether ANY regex in the array is present. Used to detect failure
# signals in the WITH run (should be absent).
signals_any_present() {
  local output="$1" sigs_var="$2" tag="$3"
  local sigs sig
  eval "sigs=(\"\${${sigs_var}[@]}\")"
  for sig in "${sigs[@]}"; do
    if printf '%s' "$output" | grep -qE "$sig"; then
      vlog "[$tag] leak HIT: $sig"
      return 0
    fi
  done
  return 1
}

run_fixture() {
  local fixture="$1"
  validate_fixture "$fixture" || return 2

  require yq
  local pack_rel pack_abs scenario
  pack_rel=$(yq -r '.pack' "$fixture")
  scenario=$(yq -r '.scenario' "$fixture")
  pack_abs="$REPO_ROOT/$pack_rel"

  # Load signal arrays via yq → newline-delimited → bash array.
  local failure_signals=() success_signals=() line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    failure_signals+=("$line")
  done < <(yq -r '.failure_signals[]' "$fixture")
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    success_signals+=("$line")
  done < <(yq -r '.success_signals[]' "$fixture")

  local stripped loaded without_out with_out
  stripped=$(compose_stripped "$scenario" "$pack_rel")
  loaded=$(compose_loaded "$pack_abs" "$scenario")

  printf '═══ %s\n' "${fixture#"$REPO_ROOT/"}"
  printf '    pack: %s\n' "$pack_rel"

  without_out=$(invoke_subagent "$stripped" "without") || true
  with_out=$(invoke_subagent "$loaded" "with") || true

  [ "$VERBOSE" -eq 1 ] && {
    printf '─── WITHOUT output ───\n%s\n' "$without_out"
    printf '─── WITH output ───\n%s\n' "$with_out"
  }

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    DRY-RUN: fixture parsed, prompts composed, no subagent spawned\n'
    return 0
  fi

  local without_ok=0 with_ok=0

  # WITHOUT run: should exhibit failure_signals.
  if signals_all_present "$without_out" failure_signals "without"; then
    without_ok=1
    printf '    [ok] WITHOUT run exhibits failure signals\n'
  else
    printf '    [BROKEN BASELINE] WITHOUT run did NOT exhibit failure signals — scenario too easy or signals too narrow\n'
  fi

  # WITH run: should exhibit success_signals AND NOT exhibit failure_signals.
  local with_success with_leak
  if signals_all_present "$with_out" success_signals "with"; then
    with_success=1
  else
    with_success=0
  fi
  if signals_any_present "$with_out" failure_signals "with"; then
    with_leak=1
  else
    with_leak=0
  fi
  if [ "$with_success" -eq 1 ] && [ "$with_leak" -eq 0 ]; then
    with_ok=1
    printf '    [ok] WITH run exhibits success signals, no failure leak\n'
  else
    printf '    [REGRESSION] WITH run success=%d leak=%d\n' "$with_success" "$with_leak"
  fi

  if [ "$without_ok" -eq 1 ] && [ "$with_ok" -eq 1 ]; then
    printf '    PASS\n'
    return 0
  fi
  printf '    FAIL\n'
  return 1
}

cmd_run() {
  local target="${1:-}" f
  [ -n "$target" ] || die "run: need <pack> (e.g. chanakya/status or chanakya/modes/status.md)" 3
  case "$target" in
    */modes/*.md|*/SKILL.md)
      f=$(fixture_path_for "$REPO_ROOT/$target")
      ;;
    */*)
      local agent="${target%%/*}" mode="${target#*/}"
      mode="${mode%.md}"
      if [ "$mode" = "SKILL" ]; then
        f=$(fixture_path_for "$REPO_ROOT/$agent/SKILL.md")
      else
        f=$(fixture_path_for "$REPO_ROOT/$agent/modes/${mode}.md")
      fi
      ;;
    *) die "run: need <agent>/<mode>" 3 ;;
  esac
  run_fixture "$f"
}

cmd_run_all() {
  local f rc total=0 failed=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    total=$((total + 1))
    if ! run_fixture "$f"; then
      failed=$((failed + 1))
    fi
  done < <(find "$FIXTURE_ROOT" -type f -name '*.yaml' 2>/dev/null | sort)
  printf '\n───\n%d fixture(s), %d failed\n' "$total" "$failed"
  [ "$failed" -eq 0 ]
}

# ---------- arg parse ----------
usage() {
  sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
  exit 3
}

main() {
  [ "$#" -ge 1 ] || usage
  local cmd="$1"; shift
  # Extract flags from remaining args.
  local positional=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --verbose) VERBOSE=1 ;;
      --model) shift; MODEL="${1:?--model needs a value}" ;;
      -h|--help) usage ;;
      --) shift; while [ "$#" -gt 0 ]; do positional+=("$1"); shift; done; break ;;
      -*) die "unknown flag: $1" 3 ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  set -- "${positional[@]+"${positional[@]}"}"

  case "$cmd" in
    list)     cmd_list ;;
    validate) cmd_validate "${1:-}" ;;
    scaffold) cmd_scaffold "${1:-}" ;;
    run)      cmd_run "${1:-}" ;;
    run-all)  cmd_run_all ;;
    -h|--help) usage ;;
    *) die "unknown subcommand: $cmd" 3 ;;
  esac
}

main "$@"
