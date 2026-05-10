---
name: artifact-cleanup-issues
description: Issue tracker for the studio artifact-cleanup migration (umbrella #854 plus per-surface Phase 2 sub-issues). Consumed by T-R005 / #851 for the CLAUDE.md citation.
type: audit-tracker
---

# Artifact-cleanup migration: issue tracker

**Baseline:** `cdbc6e9` (commit_before).
**Audit source:** `_shared/audits/2026-05-10-artifact-cleanup-audit.md`.
**Created by:** T-R002 (executed manually from parent session due to chain-runner subprocess permission boundary; see #852).

## Structured registry

```yaml
umbrella:
  number: 854
  url: https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/854
sub_issues:
  - surface: structural
    number: 855
    url: https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/855
  - surface: chain-runner
    number: 856
    url: https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/856
  - surface: perf
    number: 857
    url: https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/857
  - surface: qa-flow
    number: 858
    url: https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/858
  - surface: release-tf
    number: 859
    url: https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/859
```

## Human-readable summary

Phase 2 work-chain will pick these up after Phase 1 (#845) merges. Each sub-issue links the relevant offender rows in the audit report and proposes a fix shape using the new `register_artifact` primitive (#848) plus the lint gate seeded from the audit (#849). CLAUDE.md "Artifact cleanup (hard rule)" section (#851 / pending) cites #854 as the migration tracker.
