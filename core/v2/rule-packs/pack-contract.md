<!-- rule-pack-contract:version=1 -->
<!-- rule-pack-contract:catalog=core/v2/rule-packs/catalog.yaml -->

# Rule-Pack Metadata Contract

Rule packs split rule loading into compact summaries, on-demand full docs, and
script-readable applicability metadata. The catalog is authoritative for
resolver behavior; prose explains semantics for hosts and reviewers.

<!-- rule-pack-contract:argus-compatibility -->
## Argus Compatibility

Applicability reuses the reviewer frontmatter shape already supported by
`scripts/argus-select-rules.sh`:

```yaml
applies_when:
  any_of: [touches_swiftui]
  all_of: [role_reviewer]
  none_of: [touches_test_only]
```

`any_of: []` means always eligible for that group. All declared groups are
ANDed: at least one `any_of` key must match unless the list is empty, every
`all_of` key must match, and no `none_of` key may match. New resolver work may
add typed predicates, but it must preserve these three list operators.

<!-- rule-pack-contract:required-files -->
## Required Pack Files

Every pack must declare these fields in `core/v2/rule-packs/catalog.yaml`:

- `summary_path`: compact LLM-loadable summary.
- `full_doc_path`: complete rule or policy source.
- `metadata_path`: pack-local metadata when the pack graduates from catalog-only.
- `owner`: owning role, team, or repo surface.
- `applicability`: `any_of`, `all_of`, and `none_of` predicate lists.
- `enforcement_hooks`: scripts, hooks, or explicit manual checks.
- `fixture_refs`: regression fixtures or examples proving expected selection.

Catalog-only seed packs may point `metadata_path` at the catalog until they are
materialized as directories. A materialized pack should use:

```text
core/v2/rule-packs/<pack-id>/
  summary.md
  rules.md
  pack.yaml
```

<!-- rule-pack-contract:applicability-predicates -->
## Applicability Predicates

Predicate names are lower snake case and should map to deterministic context
fields before prompt text. The initial predicate families are:

- `role_*`: canonical Studio v2 role or compatibility alias.
- `phase_*`: plan, pre-edit, implementation, review, outcome, release, debug.
- `manifest_*`: task or chain manifest fields and explicit pack requests.
- `touches_*`: changed or planned surfaces such as git, scripts, iOS, privacy.
- `platform_*`: language, OS, SDK, profile, or project platform.
- `release_job_*`: TestFlight, App Store, Slack, signing, tagging.
- `build_job_*` / `test_job_*`: build, lint, unit, integration, UI, smoke.
- `mode_*`: review, debug, emergency, dry-run, unattended, chain-runner.

Missing optional context fields do not satisfy constrained predicates.

<!-- rule-pack-contract:budgets-and-triggers -->
## Summary Budget and Full-Doc Triggers

The always-loaded rule floor remains capped at 700 estimated tokens. Pack
summaries target 180 estimated tokens each, and the selected summary bundle
targets 1200 estimated tokens before full docs. Token estimates use `chars / 4`
rounded up.

Load a full doc only when one of these triggers fires:

- A blocking or ask-tier decision depends on exact wording.
- A script/hook named by `enforcement_hooks` will be changed or debugged.
- The compact summary and selected context conflict.
- The task edits the pack itself, its fixtures, or its owner surface.
- The operator explicitly requests the full policy.

<!-- rule-pack-contract:versioning-deprecation -->
## Versioning and Deprecation

Catalog entries carry `version`, `status`, `introduced_in`, and optional
`replaced_by` / `deprecated_at`. Resolvers must reject unknown required packs,
inactive packs without a replacement, and deprecated packs after
`deprecated_at`. Deprecation must name the successor pack or the removal reason.

<!-- rule-pack-contract:taxonomy -->
## Initial Taxonomy

The initial taxonomy is data in `catalog.yaml` and covers:

- git workflow
- source-branch integration
- iOS artifacts
- worker routing
- telemetry
- cleanup retention
- release routing
- privacy
- review
