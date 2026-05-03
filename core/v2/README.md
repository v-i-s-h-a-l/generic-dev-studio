# Studio v2 Substrate

This directory is the parallel v2 substrate root for #444.

A0.4 is intentionally narrow. It ships only bootstrap metadata, schema anchors,
and pre-commit gate scaffolding so later substrate work cannot grow without the
A0.5 SPEC sign-off.

Current bootstrap artifacts:

- `bootstrap.yaml` declares the A0.4 gate surface.
- `BOOTSTRAP.md` names the required human-readable anchors.
- `schemas/bootstrap.schema.json` defines the bootstrap manifest shape.
- `hooks/pre-commit` is the v2-local hook entry point; the repo hook delegates
  to `scripts/lint-v2-bootstrap.sh`.
- `registry/roles.json` is the A1 canonical role registry. Resolve canonical
  names and compatibility aliases with `scripts/v2-role-resolve.sh`.

Until `SPEC.md` carries `<!-- v2-bootstrap:a0.5-sign-off:complete -->`, the gate
allows substrate docs, metadata, schemas, and this bootstrap hook only. It blocks
code under `core/` and `profiles/` so A0.6-style implementation rules do not land
early.
