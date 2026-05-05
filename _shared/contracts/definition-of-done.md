---
name: Definition Of Done Contract
description: Shared completion checklist and changelog trailer convention for worker and release workflows.
type: contract
---

# Definition Of Done Contract

Done means completion evidence is explicit, not inferred from a commit subject
or a vague final note.

## Checklist

For every implementation task, worker evidence records each item as `done`,
`not_applicable`, or `waived`, with a short reason for every non-`done` item:

- Tests or equivalent verification.
- Accessibility impact.
- Localization impact.
- Performance impact.
- Analytics or telemetry impact.
- Feature flag or rollout impact.
- Changelog trailer.

The checklist is scaled by task type. Documentation-only, internal substrate,
and no-user-visible-change tasks can mark product-facing items
`not_applicable`, but they still record that judgment.

## Changelog Trailer

Commits that change user-visible behavior include one trailer:

```text
Changelog: <release-note bullet>
```

The trailer is a concise release-note candidate, written from the user's point
of view. It avoids implementation detail, private project names, branch names,
task IDs, and raw review text.

Internal-only commits use an explicit waiver instead of an empty trailer:

```text
Changelog: none (internal-only)
```

Release tooling and release-manager packets treat `Changelog:` trailers as
source material for release notes. Human editing remains allowed, but the
default path is trailer aggregation rather than reconstructing intent from
commit subjects.

## Evidence Rules

- Worker summaries name the checklist state or point to the artifact that
  carries it.
- A completion claim without checklist state is incomplete.
- A release packet that ignores available `Changelog:` trailers records why the
  trailers were insufficient or superseded.
