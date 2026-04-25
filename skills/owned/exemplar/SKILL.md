---
name: exemplar
description: Reference skill that demonstrates every rule in the Skill Authoring Standard. Used as the seed for scaffold-skill.sh and as the regression target for lint-skill-prose.sh.
type: skill
schema_version: 1
version: 1.0.0
---

# exemplar — reference skill

This skill exemplifies the Authoring Standard in working form. It does not implement real domain logic; it is the reference shape that owned skills MUST conform to. The scaffold (`scripts/scaffold-skill.sh`) seeds new skills from this file.

## What this skill does

Reads a target file path supplied at invocation time, extracts the YAML frontmatter, and emits a structured summary event. Demonstrates the full procedure-step grammar (sentinel verbs, pre/post conditions, decision tables, classified failure modes) and the affordance header.

## What this skill does not do

It does not edit the target file. It does not validate the frontmatter against any schema (the linter owns that). It does not crawl directories — input is a single file path.

## Inputs

- `target_path` — absolute path to a markdown file with YAML frontmatter, supplied via the invocation slot.

## Outputs

- One `exemplar_summary_emitted` event written to the current event log (per `_shared/contracts/event-emission.md`), payload `{path, name, type, schema_version}`.
- Stdout: a one-line JSON summary mirroring the event payload.

## When to invoke

Manually, when an author wants a structural sanity check on a SKILL.md file before running the linter. Also serves as the live test fixture for `scripts/lint-skill-prose.sh` — any change to the standard that breaks the exemplar is a regression in the standard, not the exemplar.

## Procedure

1. **READ** `target_path`.
   Before: `target_path` is set and points to a regular file.
   After:  the file's bytes are loaded into the model's context.

2. **CHECK** that the first line is `---`.
   Before: file content is loaded.
   After:  the first-line shape is known.

   Decision:
   | Case | Action |
   |---|---|
   | first line is `---` | PROCEED to step 3 |
   | first line is not `---` | BLOCK with `E_NO_FRONTMATTER` |

3. **READ** the frontmatter block (lines between the first `---` and the second `---`).
   Before: step 2 confirmed a frontmatter delimiter.
   After:  frontmatter is parsed into a key/value map.

4. **CHECK** that `name`, `description`, `type`, and `schema_version` are all present.
   Before: frontmatter map is parsed.
   After:  required-key set has been audited.

   Decision:
   | Case | Action |
   |---|---|
   | all four keys present | PROCEED to step 5 |
   | any key missing | BLOCK with `E_MISSING_REQUIRED_KEY` listing the missing keys |

5. **EMIT** `exemplar_summary_emitted` with payload `{path, name, type, schema_version}`.
   Before: required keys verified.
   After:  one event has been appended to today's event log.

6. **WRITE** the same payload as a single-line JSON object to stdout.
   Before: event has been emitted.
   After:  caller receives the summary on stdout.

7. **STOP**.
   Before: stdout has been written.
   After:  the agent session has terminated cleanly; no further steps run.

## Failure modes

| Failure | Classification | Action |
|---|---|---|
| `target_path` does not exist or is unreadable | permanent | BLOCK with `E_NO_TARGET`; do not retry |
| `target_path` is a directory, not a file | permanent | BLOCK with `E_BAD_TARGET`; do not retry |
| event log is locked by another writer | transient | RETRY once after 250ms; on second failure, ESCALATE |
| frontmatter parses but contains a key with no value | ambiguous | ESCALATE to user with the offending key in context |

## See also

- `_shared/standards/skill-authoring.md` — the standard this exemplifies.
- `_shared/standards/sentinel-vocabulary.md` — the verb set used here.
- `scripts/lint-skill-prose.sh` — the linter that gates conformance.
