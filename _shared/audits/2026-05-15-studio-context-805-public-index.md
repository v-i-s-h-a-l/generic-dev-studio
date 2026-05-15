# Studio Context #805 Public Index

This public index records sanitized proof that the private-runtime RCA and
inventory for issue #805 were produced for issue #912. It intentionally omits
private runtime payloads, local machine paths, detailed file:line scan results,
and telemetry bodies.

## Private Artifacts

| Artifact | Visibility | Public status |
|---|---|---|
| `resolved-generic-dev-studio-analysis-runtime/studio-context-rca-805.md` | private-runtime | Produced; not committed |
| `resolved-generic-dev-studio-analysis-runtime/studio-context-inventory-805.json` | private-runtime | Produced; not committed |

## RCA Section Checklist

| Required section | Status |
|---|---|
| Summary | present |
| Root cause | present |
| Contributing factors | present |
| Impact | present |
| Inventory schema | present |
| Search scope | present |
| Aggregate findings | present |
| Verification fixtures | present |
| Public hygiene constraints | present |
| Stop-condition evaluation | present |

## Inventory Schema Checklist

| Field | Status |
|---|---|
| `schema_version` | present |
| `generated_for` | present |
| `visibility` | present |
| `search_scope` | present |
| `classification_rules` | present |
| `aggregate_counts` | present |
| `production_hotspots` | present with repo-relative paths only |
| `verification` | present |
| `public_hygiene` | present |
| `stop_conditions` | present |

## Search Scope Summary

The inventory scan used `rg` over repository source-like content, excluding Git
metadata, private runtime artifacts, dependency/vendor folders, and lockfiles.
The pattern family covered raw durable runtime paths, synthetic-home markers,
GitHub/auth wrapper usage, host auth variables, Studio context envelope
variables, resolver helper names, and raw `HOME` command environment usage.

## Aggregate Counts

| Operation class | Risk | Match count | File count |
|---|---:|---:|---:|
| approved_resolver | low | 211 | 3 |
| docs_contract | low | 370 | 87 |
| fixture_only | low | 908 | 135 |
| other | medium | 161 | 27 |
| production | high | 220 | 80 |
| production | medium | 487 | 81 |

## Verification Evidence

| Command | Outcome |
|---|---|
| `rg` inventory aggregation command | passed; produced operation_class/risk counts above |
| `env -u CODEX_REVIEWER_HOME -u CLAUDE_REVIEWER_HOME -u CODEX_HOME -u CODEX_WORKER_HOME scripts/test-fixtures/732-studio-context/test-studio-context.sh` | passed; clean auth-home environment used so the fixture exercises default reviewer-home resolution |
| `tests/lib-host-eligibility/test-lib-host-eligibility.sh` | passed |
| Public hygiene scan for absolute paths, token-like secrets, private chain artifact names, and private artifact body leakage | passed |

## Public Hygiene Result

The intended public surface is limited to artifact names, checklist status,
aggregate counts, verification outcomes, and public-safe follow-up placeholders.
Private RCA text, private inventory bodies, detailed file:line results, tokens,
credential material, host-auth payloads, and machine-specific absolute paths
must remain out of this committed file and out of issue comments.

## Public-Safe Follow-Ups

- Use the aggregate `production` buckets to prioritize the next issue's
  production migration plan.
- Keep fixture-only matches as regression coverage unless a fixture duplicates
  obsolete behavior without an assertion.
- Keep future public summaries aggregate-only; store detailed scan payloads in
  private runtime artifacts.
