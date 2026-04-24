---
name: Schema Evolution
description: FULL_TRANSITIVE compatibility + additive-only evolution rules for every JSON Schema under _shared/contracts/. Writers and readers can roll out in any order; pre-cutover artifacts stay readable forever. Integer `schema: <int>` is the canonical schema-doc version. Date-pinning and SemVer are rejected — see §Rejected alternatives.
type: reference
---

# Contract Schema Evolution

Rules governing how every `*.schema.json` under `_shared/contracts/` changes over time. Authored 2026-04-25 as part of host-agnostic workers v1 (#88). This file, together with `contracts/schema-version.md`, is the discipline that keeps cross-host / cross-session artifacts compatible.

## Model — FULL_TRANSITIVE + additive-only

**FULL_TRANSITIVE compatibility.** Every writer must produce artifacts every active reader can understand, and every reader must accept every artifact every active writer produces. Rolling upgrades in either direction are free. The cost: all changes are additive — new fields with defaults — until the entire fleet has rolled forward.

Contrast: FORWARD compatibility allows old readers to parse new data (ignoring unknowns). BACKWARD allows new readers to parse old data. FULL is both. FULL_TRANSITIVE is FULL across every version pair in the active window, not just adjacent pairs.

## The five rules

1. **New fields require defaults.** Either the schema supplies `default: <value>` or the field is optional (not listed in `required`) and consumers treat its absence as a defined default. Absent + default-documented is preferred over explicit `default:` because YAML serializers often round-trip `default:` values as literals, hiding the fact that the writer didn't set them.

2. **No removals — deprecate in description.** A field whose purpose has passed stays in the schema with `"deprecated": true` and a `description` pointing at the successor. It leaves the schema only when every artifact in every project's archive is known to not reference it — effectively, never.

3. **No renames.** Add the new name as a field; dual-write both for the transition window; eventually deprecate the old. Renames masquerading as simple edits are the most common schema-evolution regression.

4. **Type tightening bumps `schema:`.** Widening a type (`string → string | null`) is additive. Tightening (`string | null → string`) breaks readers that previously accepted `null`. Bump the schema's root-level `schema: <int>`.

5. **Every bump archives the prior validator.** Before committing a `schema:` bump, copy the prior schema file to `_shared/contracts/archive/v<N>/<schema-name>.schema.json`. Old artifacts can still be validated against their contemporaneous schema; no re-validation is forced.

## Integer `schema: <int>` is the canonical schema-doc version

Every `*.schema.json` in this directory carries `"schema": <int>` at the root, starting at `1`. This number versions the **schema document itself** — not the artifact it validates. Bump it per rule 4; archive the prior rule 5.

The artifact payloads continue to carry `schema_version: {name, version, min_reader, deprecated_at}` (the object form documented in `contracts/schema-version.md`) during the transition window. Post-v1, new artifact types should prefer `schema: <int>` on the payload too, matching the schema-doc convention. Old-shape `schema_version` objects remain readable indefinitely per rule 2.

### Rejected alternatives

- **SemVer for schema docs.** Patch/minor/major carry no useful distinction between sibling schemas (what's a "patch" on `handoff.schema.json`?). Readers end up pattern-matching the major anyway. One integer does the same work with less prose.
- **Stripe-style date-pinning** (`"schema": "2026-04-25"`). Useful when external clients pin to a specific day and the producer guarantees bug-for-bug identical behavior thereafter. This project has zero external pinning clients and no appetite to maintain behavioral equivalence across dated branches.
- **Git-hash-as-version.** Makes diffs unintuitive; no monotonic ordering without a side index.

## Validator tool — `check-jsonschema`

Pure Python, installable via `pipx install check-jsonschema` or `pip install check-jsonschema`. Chosen over `ajv-cli` (node dep chain) and `yq`-with-schema (limited draft-2020-12 support) in pass-2 of #88.

Every wrapper that reads / writes contract-governed artifacts invokes it through `scripts/validate-contract.sh` (authored in #117 — H4). Direct invocation from scripts without that wrapper is a lint violation (flagged by `lint-host-agnostic.sh` — #119).

### Cross-file `$ref` resolution

Each schema's `$id` is its bare filename (`debrief.schema.json` etc.), and cross-schema `$ref` uses filename-relative URIs (`debrief.schema.json#/$defs/uuidv7`). This keeps the schemas portable — they don't embed absolute URLs or host-specific paths. **The validator must run with `_shared/contracts/` as the working directory so relative refs resolve to sibling files.** `scripts/validate-contract.sh` handles this via `cd` before invoking `check-jsonschema`; direct invocations must do the same.

## Bump workflow (writer side)

1. Decide the change is non-additive (otherwise: just add fields, no bump).
2. Copy current `_shared/contracts/<name>.schema.json` → `_shared/contracts/archive/v<current>/<name>.schema.json`.
3. Edit the live file. Bump `"schema": <N+1>`.
4. Update every emitter in the same commit so no writer emits against the prior schema going forward.
5. Grep consumers for the schema name; update any hard-coded schema paths.
6. Walk `REVIEW.md` before commit. A schema bump touches `_shared/*` which triggers review automatically.

## Archive directory

`_shared/contracts/archive/v<N>/` holds the pre-bump copy of each schema. Readers that encounter an artifact claiming `schema: N` while the live schema is `N+M` fall through the versions in descending order, validating against `v<live>` first, then `v<live-1>`, etc. A reader with no matching archive entry fails loud.

## What this is NOT

- A replacement for `contracts/schema-version.md` — that file remains the ground truth for the object-form version record on artifacts.
- A promise that code behavior is backward compatible. This is about *data shapes*. Behavioral changes still get coordinated through normal release discipline.
- An invitation to bump `schema:` frequently. Each bump carries a real cost: archive entry, reader logic, consumer updates. Prefer additive.

## Related

- `contracts/schema-version.md` — object-form version record on payloads.
- `contracts/worker-report.schema.json` — four-state enum + per-state required-field matrix.
- `contracts/debrief.schema.json` — Achilles-authored debrief.
- `contracts/review-verdict.schema.json` — Argus verdict.
- `contracts/handoff.schema.json` — typed handoff envelope (dispatch-review.sh, spawn-worker.sh).
- `contracts/idempotency.md` — retry classification + key construction.
