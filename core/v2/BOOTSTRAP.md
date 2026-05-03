# Studio v2 Bootstrap Gate

<!-- v2-bootstrap:a0.4-scope -->
## A0.4 Scope

A0.4 protects the v2 substrate while it is still being specified. It does not
define runtime behavior, role implementations, event-log invariants, profile
commands, or SPEC-derived rules.

<!-- v2-bootstrap:schema-presence -->
## Schema Presence

The bootstrap manifest lives at `core/v2/bootstrap.yaml` and its schema lives at
`core/v2/schemas/bootstrap.schema.json`. The pre-commit gate fails if either file
is missing.

<!-- v2-bootstrap:required-anchors -->
## Required Anchors

The bootstrap gate keeps these anchors present so later leaves can link to the
same bootstrap contract instead of restating it.

<!-- v2-bootstrap:pre-a0.5-code-freeze -->
## Pre-A0.5 Code Freeze

Before A0.5 sign-off, substrate changes under `core/` and `profiles/` may add
documentation, YAML metadata, JSON schemas, and the bootstrap hook. They may not
add executable or source-code implementation files.

<!-- v2-bootstrap:a0.6-deferred-rules -->
## A0.6 Deferred Rules

A0.6 owns full SPEC-derived enforcement. A0.4 only checks bootstrap/meta rules:
schema presence, required anchors, the pre-A0.5 substrate-code freeze, and this
deferred-rule boundary.
