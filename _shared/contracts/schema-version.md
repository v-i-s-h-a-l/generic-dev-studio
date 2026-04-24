---
name: Schema Version Contract
description: Every YAML / JSON / message carries a schema_version object (SemVer + min_reader + deprecated_at). Readers below min_reader reject loudly; deprecations are announced before hard-break.
type: reference
---

# Schema Version Contract

Every structured artifact — messages, schemas, briefs, debriefs, review verdicts — carries a `schema_version` object. Single-user project at this scale rarely sees divergent reader versions, but pinning semantics early means later phases (2.6 ledger overhaul, 2.7 knowledge layer) inherit the discipline rather than retrofit it.

## Shape

```yaml
schema_version:
  name: "brief"           # stable identifier for the schema
  version: "3.1.0"        # SemVer — major=breaking, minor=additive, patch=fix
  min_reader: "3.0.0"     # readers below this MUST reject, not degrade silently
  deprecated_at: null     # RFC3339 UTC string when this version retires, or null
```

JSON form is the same, flatter:

```json
{"name": "brief", "version": "3.1.0", "min_reader": "3.0.0", "deprecated_at": null}
```

## Rules

1. **SemVer interpretation.**
   - **Major** — required field added / removed / renamed; field type changed; enum value removed. Readers on the prior major MUST reject.
   - **Minor** — optional field added; new enum value added; doc-only clarifications. Readers on the prior minor MUST NOT fail; they ignore unknown fields.
   - **Patch** — typo fix, wording tweak, schema-file-only edit that leaves producers and consumers unchanged.
2. **`min_reader` is load-bearing.** Producers set `min_reader` to the lowest reader version that can still parse this message correctly. A reader below `min_reader` MUST reject loudly (error emitted; message not processed). Silent degradation is a correctness bug.
3. **Deprecations are announced.** When a schema version is scheduled for retirement, set `deprecated_at` to the target retirement date (RFC3339 UTC). Producers emit a `schema_deprecated` event (one-time per session) so consumers can upgrade before hard-break. Null `deprecated_at` means current-stable.
4. **Schemas live in `schemas/<name>.md`.** Each schema file carries a history table (`version | landed | notes`). New majors land with a plan for phasing out the prior major.
5. **Reader behavior on unknown fields.** Ignore, do not fail. Minor-version additions are additive; rejecting on unknown fields would break forward compatibility.
6. **Reader behavior on missing required fields.** Reject with `E_SCHEMA_REQUIRED_MISSING`. Never infer defaults.

## History table — template

Every `schemas/<name>.md` file ends with:

| Version | Landed | Changes |
|---|---|---|
| 3.1.0 | 2026-04-22 | Added optional `parent_task` field. |
| 3.0.0 | 2026-04-10 | Required `correlation_id`; removed legacy `brief_number`. |

## Example — versioning a debrief

Producer:

```yaml
schema_version:
  name: "debrief"
  version: "2.0.0"
  min_reader: "2.0.0"
  deprecated_at: null
```

Consumer:

```bash
if ! version_ge "$reader_version" "$payload.schema_version.min_reader"; then
  emit_error "E_SCHEMA_VERSION_MISMATCH" "reader=$reader_version min=$payload.schema_version.min_reader"
  exit 1
fi
```

## Non-goals

- Semantic migrations between majors — that is a per-schema concern (see e.g. the 2.6 ledger migration plan).
- Runtime version negotiation. Producers pick the version they publish; readers decide whether to accept. No handshake.

## Related

- `message-contract.md` — envelope carries `schema_version`.
- `idempotency.md` — content-hash is computed post-normalization against the schema.
- `schemas/` — one file per schema `name`, each with its own history.
- `EVOLUTION.md` — FULL_TRANSITIVE + additive-only rules for the formal `*.schema.json` files under this directory. Names the canonical integer `schema: <int>` form on schema docs and the transition from object-form `schema_version` on payloads.
