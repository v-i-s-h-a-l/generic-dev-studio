#!/usr/bin/env bash
# Regression fixture for #793 — prd-task-graph-synthesize.sh used to scrape
# every backticked path-shaped token from a component body, conflating writes
# with references, verification commands, format alternates, and section-level
# pattern references. This fixture pins the corrected behavior:
#
# - Bare extension tokens (`.json`) do NOT land in write_resources.
# - Shell-command literals (`grep -n "X" foo.sh`) do NOT land in
#   write_resources.
# - Reference sections (Edges and prior art, Verification) suppress backtick
#   extraction.
# - Title backticked paths land in write_resources.
# - Body backticked paths require a write-verb in the same paragraph, so
#   "pattern reference" tokens stay out.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
RUN="$ROOT/scripts/prd-task-graph-synthesize.sh"
TMPROOT=$(mktemp -d -t planner-hygiene.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$RUN" ] || fail "scripts/prd-task-graph-synthesize.sh is not executable"
command -v jq >/dev/null 2>&1 || { printf 'SKIP: jq required\n'; exit 0; }

SOURCE="$TMPROOT/polluted-source.md"
GRAPH="$TMPROOT/graph.json"

cat >"$SOURCE" <<'EOF'
# Test arc — write/reference disambiguation

## Why

Reproduces the path-extraction failure modes from #793. Each component is
authored to look plausible while embedding the four classic pollutants:
references, verification commands, alternates, and pattern references.

## Scope (in)

### 1. Schema + default profile file

- The schema spec is created at `_shared/contracts/test-schema.md`.
- The default profile file is created at `_shared/profiles/default.yaml`
  (alternate format `.json` discussed but YAML wins; planner picks).
- Inventory of consumer scripts (read-only for this arc):
  - `scripts/foo-consumer.sh`
  - `scripts/bar-consumer.sh`

### 2. Resolver library (`scripts/lib-test-resolver.sh`)

- Library file: writes will land at `scripts/lib-test-resolver.sh`.
- Pattern reference: see `scripts/lib-studio-context.sh` for the sourceable
  shell library convention used elsewhere in the studio.

### 3. Eligibility library (`scripts/lib-test-eligibility.sh`)

- Library file: writes to `scripts/lib-test-eligibility.sh`.
- Verification command: `grep -n "STUDIO_HOST" scripts/lib-test-resolver.sh`
  proves the library wires up correctly.

### 4. Chain runner integration

Touches `scripts/test-chain-runner.sh` (line 5612 literal removal).

### 5. Halt-record schema

Updates `_shared/contracts/test-envelope.md` and `scripts/lib-test-run-state.sh`
across multiple wrapped lines. The reviewer surfaces the resolved host in
`scripts/test-chain-monitor.sh` user-facing output as well.

### 6. Documentation

- Document `STUDIO_BYPASS_TEST_HYGIENE=1` in `CLAUDE.md`.
- Update `hosts/ADAPTER-SPEC.md` with a forward pointer.
- No new top-level rules in `REVIEW.md`. The block-tier rules are deferred.

## Edges and prior art in the repo

- `scripts/foo-consumer.sh` — read-only inventory reference.
- `scripts/lib-studio-context.sh` — pattern reference, not a write target.
- `scripts/test-chain-runner.sh:5612` — anchor line for the integration.

## Verification

- `bash -n scripts/lib-test-resolver.sh`
- `grep -n "STUDIO_HOST" scripts/lib-test-eligibility.sh`
EOF

"$RUN" "$SOURCE" >"$GRAPH" 2>"$TMPROOT/synth.err" \
  || { sed -n '1,40p' "$TMPROOT/synth.err" >&2; fail "synthesis exited non-zero"; }

# Helper: read write_resources for a node id
writes_for() {
  jq -r --arg id "$1" '.nodes[] | select(.id == $id) | .write_resources | join(",")' "$GRAPH"
}

t1=$(writes_for T-R001)
t2=$(writes_for T-R002)
t3=$(writes_for T-R003)
t4=$(writes_for T-R004)
t5=$(writes_for T-R005)
t6=$(writes_for T-R006)

# Each assertion checks one of the original 10 fatal items from #793.

# T-R001: must NOT contain bare `.json` (alternate-format token).
case ",$t1," in *,.json,*) fail "T-R001 contains bare .json (alternate token leaked)";; esac

# T-R001: must NOT contain consumer-inventory scripts (read-only references).
case ",$t1," in
  *,scripts/foo-consumer.sh,*) fail "T-R001 leaked consumer inventory script";;
  *,scripts/bar-consumer.sh,*) fail "T-R001 leaked consumer inventory script";;
esac

# T-R001: SHOULD contain the legitimate write targets.
case ",$t1," in
  *,_shared/contracts/test-schema.md,*) :;;
  *) fail "T-R001 missing _shared/contracts/test-schema.md (got: $t1)";;
esac
case ",$t1," in
  *,_shared/profiles/default.yaml,*) :;;
  *) fail "T-R001 missing _shared/profiles/default.yaml (got: $t1)";;
esac

# T-R002: must contain its named library (regression: was missing).
case ",$t2," in
  *,scripts/lib-test-resolver.sh,*) :;;
  *) fail "T-R002 missing scripts/lib-test-resolver.sh (got: $t2)";;
esac

# T-R002: must NOT contain pattern-reference path lib-studio-context.sh.
case ",$t2," in
  *,scripts/lib-studio-context.sh,*) fail "T-R002 leaked pattern-reference path";;
esac

# T-R003: must contain its named library and NOT the verification grep command.
case ",$t3," in
  *,scripts/lib-test-eligibility.sh,*) :;;
  *) fail "T-R003 missing scripts/lib-test-eligibility.sh (got: $t3)";;
esac

# T-R003 / T-R004: must NOT contain the literal "grep -n ..." shell command.
for w in "$t3" "$t4" "$t5"; do
  case "$w" in
    *grep*-n*) fail "shell command literal leaked into write_resources: $w";;
  esac
done

# T-R004: must NOT have any path containing whitespace or shell syntax.
for w in "$t1" "$t2" "$t3" "$t4" "$t5" "$t6"; do
  case "$w" in
    *' '*|*'--'*|*'>'*|*'$('*) fail "shell-syntax write_resource leaked: $w";;
  esac
done

# T-R005: paragraph-wrap must not drop paths from a multi-line write paragraph.
case ",$t5," in
  *,_shared/contracts/test-envelope.md,*) :;;
  *) fail "T-R005 missing _shared/contracts/test-envelope.md (got: $t5)";;
esac
case ",$t5," in
  *,scripts/lib-test-run-state.sh,*) :;;
  *) fail "T-R005 missing scripts/lib-test-run-state.sh (got: $t5)";;
esac

# T-R006: must contain CLAUDE.md (Document verb), must NOT contain REVIEW.md
# (negation phrasing — "No new top-level rules in REVIEW.md").
case ",$t6," in
  *,CLAUDE.md,*) :;;
  *) fail "T-R006 missing CLAUDE.md (got: $t6)";;
esac
case ",$t6," in
  *,REVIEW.md,*) fail "T-R006 leaked REVIEW.md (forbidden by source brief)";;
esac
case ",$t6," in
  *,hosts/ADAPTER-SPEC.md,*) :;;
  *) fail "T-R006 missing hosts/ADAPTER-SPEC.md (got: $t6)";;
esac

# Validation must report no parallel-write races and not leave empty
# allowed_paths arrays for the contracts above.
empty_count=$(jq '[.validation.empty_allowed_paths[]?] | length' "$GRAPH")
[ "$empty_count" = "0" ] || fail "validation reported $empty_count empty allowed_paths nodes"

printf 'PASS: planner allowed_paths hygiene rejects shell syntax, bare extensions, references, and negation phrasing\n'
