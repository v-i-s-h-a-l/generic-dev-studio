---
name: Chanakya Feedback Reports
description: Render reporter-facing feedback reports — design (category=design or UI/UX module) and product (category=clarification/enhancement). Read-only; writes a dated markdown file to chanakya-inbox. Sub-commands report-design and report-product.
type: mode-pack
snapshots: [feedback-inbox.json]
budget_tokens: 2500
reads:
  - plans/feedback/*.yaml                          # post-migration feedback artifacts (schema: _shared/schemas/feedback.md)
  - plans/index.yaml                               # post-migration feedback index
  - feedback/active.md                             # legacy active feedback (until Commit H)
  - feedback/archive/build-*.md                    # legacy per-build archives (until Commit H)
  - .runtime/state/chanakya-snapshots/feedback-inbox.json
writes:
  - plans/chanakya-inbox/design-report-<date>.md   # legacy report location (retained; unchanged in Commit F)
  - plans/chanakya-inbox/product-report-<date>.md  # legacy report location (retained; unchanged in Commit F)
---

# Mode: Report-Design (`/chanakya report-design [--build N]`)

Render a design-team-facing report.

Snapshots: `snapshots/feedback-inbox.json` for the active-record pass (5-min freshness; fallback: read `feedback/active.md` + `feedback/archive/build-<N>.md` directly — the feedback-report's primary inputs are always files-on-disk, so a null/stale snapshot is fine).

## Filter

- `category ∈ {design}` OR `module ∈ {UI, UX, design}` (case-insensitive).
- Status in `{new, triaged, in-progress, fixed, verified}` (exclude archived unless `--build N` is passed, in which case include archived for that build only).

## Output

Markdown table + detail blocks. Printed to stdout and written to `~/.dev-studio/<project>/plans/chanakya-inbox/design-report-<YYYY-MM-DD>.md`.

```markdown
# Design Feedback — <date> [--build N if scoped]

| F-id | Reporter | Module | Status | Reported Build | Linked Task |
|------|----------|--------|--------|----------------|-------------|
| F007 | @pranjali | Crop | triaged | 3140 | T215 |

---

## F007 — Crop reset doesn't reset rotation

**Reporter:** @pranjali
**Reported:** build 3140 (slack-thread:#ios-testflight/1745000000.000400)
**Chanakya's interpretation:** the reset button on the crop view should restore both the crop rect AND the rotation state. Currently it only resets the rect.
**Screenshot:** ![F007](chanakya-inbox/assets/thread-1745000000/F007-crop-reset.png) _or_ `(deleted — F007-crop-reset.png, …)`
**Linked task:** T215 (`in-progress`)
**Status:** triaged

> Original message:
> "When I rotate and then hit reset, the rotation doesn't go back. Expected: full reset."
```

## `--build N`

Filter to records with `reported_build == N` OR `fixed_build == N`.

---

# Mode: Report-Product (`/chanakya report-product [--build N]`)

Same format as Report-Design but filtered to `category ∈ {clarification, enhancement}`. Intended audience: Toufiq (PRD) and BE team.

Written to `chanakya-inbox/product-report-<YYYY-MM-DD>.md`.
