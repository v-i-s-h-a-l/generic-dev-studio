---
name: Base Staleness Threshold
description: Canonical drift floor used by worker pre-refresh and reviewer base-staleness checks.
type: primitive
---

# Base Staleness Threshold

Threshold: 2

Rationale: refreshing one or two commits is cheap enough to avoid reviewer staleness; beyond that, the branch should be refreshed explicitly before review.

Consumers:

- `scripts/achilles-refresh-base.sh` reads `Threshold:` as the default pre-review refresh floor.
- `core/v2/reviewer/rules/base-staleness.md` points at this file so the review rule and the refresh script share one source of truth.
- `ACHILLES_BASE_REFRESH_THRESHOLD` remains a per-run override for exceptional cases.
