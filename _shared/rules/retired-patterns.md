---
name: retired-patterns
description: Machine-readable catalog of behavioral patterns retired from mode pack prose. lint-mode-pack.sh MP5 blocks on any match across all agents.
type: rule
schema_version: 1
---

# Retired patterns

When a script, lib, or shared contract retires a write path, naming convention, or behavioral pattern, add an entry here **in the same commit**. `scripts/lint-mode-pack.sh` MP5 reads the patterns block below and blocks on any match in any `*/modes/*.md` or `*/SKILL.md` file across all agents.

This is the machine-enforced complement to REVIEW.md R21 (the human gate for paraphrased references the grep can't see).

## Catalog

| Pattern (ERE) | Retired in | Reason | Replacement |
|---|---|---|---|
| `legacy\s+markdown` | #245 A.5 (2026-04-27) | dual-write removed from lib-ledger | write YAML artifact only via lib-ledger writers |
| `write.*legacy.*\.md` | #245 A.5 (2026-04-27) | dual-write removed from lib-ledger | write YAML artifact only via lib-ledger writers |
| `DUAL_WRITE_MODE` | #245 A.5 (2026-04-27) | mode no longer consulted — yaml-only is default | remove the reference entirely |
| `chanakya-inbox/` | #245 A.4 (2026-04-27) | legacy inbox archived to plans/.legacy-archive | use `plans/tasks/*.yaml` via lib-ledger |
| `chanakya-tasks/` | #245 A.4 (2026-04-27) | legacy tasks archived to plans/.legacy-archive | use `plans/tasks/*.yaml` via lib-ledger |
| `legacy_[a-zA-Z_]+_helpers` | #245 A.5 (2026-04-27) | helpers now stub-fail (exit 9) | use lib-ledger writers directly |
| `plans/\.legacy-archive` | #245 A.4 (2026-04-27) | archive dir is read-only — no new writes | use `plans/tasks/*.yaml` via lib-ledger |
| `project-memory.*reviews.*\.md` | #245 A.5 (2026-04-27) | legacy review markdown retired | write `plans/reviews/<id>.yaml` via argus-emit-verdict.sh |

## Adding an entry

When retiring a pattern:

1. Add a row to the catalog table above (human context).
2. Add the ERE to the `<!-- lint:patterns:start -->` block below (one pattern per line; full-line `#` comments and blank lines are ignored; no inline `#` comments — put context in the table).
3. Run `scripts/lint-mode-pack.sh` across all mode packs and fix any hits in the same commit.
4. Reference this file in the commit message so the trail is traceable.

## Patterns

<!-- lint:patterns:start -->
# Lines starting with # are comments. Blank lines are ignored.
# Each non-comment line is an ERE matched with grep -E against every mode pack and SKILL.md.
# No inline comments — put human context in the catalog table above.

legacy\s+markdown
write.*legacy.*\.md
DUAL_WRITE_MODE
chanakya-inbox/
chanakya-tasks/
legacy_[a-zA-Z_]+_helpers
plans/\.legacy-archive
project-memory.*reviews.*\.md
<!-- lint:patterns:end -->
