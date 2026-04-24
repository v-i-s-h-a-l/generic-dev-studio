#!/usr/bin/env bash
# validate-contract.sh — JSON Schema validation for inter-agent contracts.
#
# RETRY POLICY: validator rejections NEVER auto-retry. Fail loud, bubble to
# Chanakya. See _shared/contracts/idempotency.md §Per-step retry classification.
#
# Usage:
#   scripts/validate-contract.sh <schema-name> <file>
#
# <schema-name>: worker-report | debrief | review-verdict | handoff
# <file>:        path to artifact (JSON or YAML — check-jsonschema handles both)
#
# Exit 0  — payload is valid against the named schema.
# Exit 1  — schema violation (one-line reason on stderr).
# Exit 2  — bad args, missing schema file, or check-jsonschema not found.
#
# Known callers:
#   write_debrief_artifact   (scripts/lib-ledger.sh)  — debrief pre-atomic-rename
#   write_review_artifact    (scripts/lib-ledger.sh)  — verdict pre-atomic-rename
#   dispatch-review.sh       (H9 — not yet implemented)  — handoff payload validation

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

SCHEMA_NAME="${1:?usage: validate-contract.sh <schema-name> <file>}"
ARTIFACT="${2:?file required}"

shift 2

# Map schema names to file paths. All schemas live in _shared/contracts/.
case "$SCHEMA_NAME" in
  worker-report)   SCHEMA_FILE="$REPO_ROOT/_shared/contracts/worker-report.schema.json" ;;
  debrief)         SCHEMA_FILE="$REPO_ROOT/_shared/contracts/debrief.schema.json" ;;
  review-verdict)  SCHEMA_FILE="$REPO_ROOT/_shared/contracts/review-verdict.schema.json" ;;
  handoff)         SCHEMA_FILE="$REPO_ROOT/_shared/contracts/handoff.schema.json" ;;
  *)
    printf 'validate-contract: unknown schema %s (want worker-report|debrief|review-verdict|handoff)\n' \
      "$SCHEMA_NAME" >&2
    exit 2
    ;;
esac

if [ ! -f "$SCHEMA_FILE" ]; then
  printf 'validate-contract: schema not found: %s\n' "$SCHEMA_FILE" >&2
  exit 2
fi

if [ ! -f "$ARTIFACT" ]; then
  printf 'validate-contract: artifact not found: %s\n' "$ARTIFACT" >&2
  exit 2
fi

# Require check-jsonschema. The tool supports --format=yaml natively so we pass
# YAML artifacts directly — no yq conversion needed.
if ! command -v check-jsonschema >/dev/null 2>&1; then
  printf 'validate-contract: check-jsonschema not installed; run: pip install check-jsonschema\n' >&2
  exit 2
fi

# All studio contracts are YAML. Pass --format=yaml unconditionally so the
# caller doesn't need to rename temp files to .yaml for format detection.
# Run the validator. Capture output — surface only the one-line summary on
# failure to keep the signal-to-noise ratio high for callers.
if ! result=$(check-jsonschema --format=yaml --schemafile "$SCHEMA_FILE" \
    --base-uri "file://$REPO_ROOT/_shared/contracts/" "$ARTIFACT" 2>&1); then
  # Extract the first "Schema violation" or "ValidationError" line for the
  # one-liner. Fall back to the full output if parsing fails.
  one_line=$(printf '%s\n' "$result" \
    | grep -E 'ValidationError|Schema violation|error:|failed' \
    | head -1 2>/dev/null)
  if [ -z "$one_line" ]; then
    one_line=$(printf '%s\n' "$result" | head -1)
  fi
  printf 'validate-contract[%s]: INVALID — %s\n' "$SCHEMA_NAME" "$one_line" >&2
  exit 1
fi

exit 0
