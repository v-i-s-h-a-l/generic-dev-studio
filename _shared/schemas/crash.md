---
name: Crash Schema
description: YAML shape for Crashlytics-derived crash records under plans/crashes/<crash-id>.yaml. Minted by Chiron (Phase 5) when a Crashlytics issue crosses a freshness threshold. Placeholder in 2.6 — real writers land in Phase 5.
type: reference
---

# Crash Schema (`crash@1.1.0`)

Per-crash artifact written to `~/.dev-studio/<project>/plans/crashes/<crash-id>.yaml`. One file per distinct Crashlytics issue (grouped by stack-trace fingerprint). Authored by Chiron (Phase 5); 2.6 lands the schema so downstream consumers have a stable write target when the writer arrives.

The shape below is finalized against the Crashlytics API and the Chiron design in `PHASE-5-PLAN.md`. 2.6 introduces no writer — the artifact dir is created on demand.

## Shape

```yaml
schema_version:
  name: crash
  version: 1.1.0
  min_reader: 1.0.0
  deprecated_at: null
id: 0190f52b-0000-7100-8ccc-99ff00aa11bb        # UUIDv7
state: ingested                                  # ingested | triaged | linked | fixed | regressed | archived
crashlytics_issue_id: "507f1f77bcf86cd799439011"
issue_title: "SIGSEGV in FilterPresetStore.applyPreset"
public_label: "Crash in filter preset application"     # public-safe label for commits, PRs, and release/build notes
public_crash_url: "https://console.firebase.google.com/…" # Crashlytics issue URL allowed in public artifacts
fix_confidence: null                                  # fixed | possibly_fixed | mitigated | duplicate | cannot_reproduce | null
fingerprint_sha256: "a1b2c3d4e5f6…"              # stack-trace fingerprint from Crashlytics
first_seen_at: 2026-04-20T08:15:00Z
last_seen_at: 2026-04-22T14:02:11Z
builds_affected:
  - "TF-3046"
  - "TF-3047"
versions_affected:
  - "1.11.0"
  - "1.12.0"
occurrence_count: 42
users_affected: 18
sample_stack_trace: |
  Thread 0 Crashed:
  0   libswiftCore.dylib     0x00000001a9c01234 swift_unknownObjectRetain + 16
  1   Project                 0x0000000102a03f10 FilterPresetStore.applyPreset(_:) + 144
  2   Project                 0x0000000102a04120 FilterPresetRow.body.getter + 288
  …
device_breakdown:
  - device: "iPhone 15"
    count: 18
  - device: "iPhone 14 Pro"
    count: 12
  - device: "iPhone SE (3rd gen)"
    count: 12
os_breakdown:
  - os_version: "iOS 17.4"
    count: 24
  - os_version: "iOS 16.4"
    count: 18
linked_tasks:
  - 0190f52a-6e0c-7b3c-9a1d-0d4e9b7f6a11
linked_feedback:
  - 0190f52a-a000-7001-8bbb-88ff9fa11ccc
fixed_in:
  release_id: null                               # release-id that fixed the crash
  commit_sha: null
  verified_no_regression_for_builds: []          # builds post-fix with zero occurrences
propagation:
  chain_run_id: null                             # chain-run UUID when processed through a crash-fix chain
  issue_numbers: []                              # public GitHub issues/PRs that carried the public-safe projection
  commit_shas: []                                # commits whose body references this crash publicly
  build_numbers: []                              # TestFlight/App Store builds including the fix
  release_ids: []                                # releases that mention or close out the crash fix
  crashlytics_closeout: null                     # annotated | queued | skipped | null
notes: null
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | object | yes | Per `contracts/schema-version.md`. |
| `id` | string (UUIDv7) | yes | |
| `state` | enum | yes | `ingested` \| `triaged` \| `linked` \| `fixed` \| `regressed` \| `archived`. |
| `crashlytics_issue_id` | string | yes | Firebase Crashlytics issue identifier (stable across polls). |
| `issue_title` | string | yes | Crashlytics-provided label (may include method signature + exception type). |
| `public_label` | string \| null | no | Short human-safe summary for commits, PRs, build summaries, release notes, and chain-worker prompts. Must not include stack frames, user/session/device identifiers, raw payload fields, or private Crashlytics dumps. Default `null` means public artifacts fall back to `public_crash_url` only. |
| `public_crash_url` | string \| null | no | Crashlytics issue URL that may appear in public GitHub commits, PR descriptions, and release/build notes when the repository accepts those links. Default `null`. |
| `fix_confidence` | enum \| null | no | `fixed` \| `possibly_fixed` \| `mitigated` \| `duplicate` \| `cannot_reproduce` \| `null`. Drives public-safe wording for crash-fix summaries. Default `null` means confidence unknown. |
| `fingerprint_sha256` | string | yes | Hash of the normalized stack trace — used for correlation. |
| `first_seen_at` | RFC3339 UTC | yes | Earliest occurrence timestamp from Crashlytics. |
| `last_seen_at` | RFC3339 UTC | yes | Most recent occurrence at ingest time. |
| `builds_affected` | array of strings | yes | Build tags where the crash was observed. |
| `versions_affected` | array of strings | yes | Marketing versions where the crash was observed. |
| `occurrence_count` | integer ≥ 0 | yes | Total occurrences (all users, all builds) at ingest time. |
| `users_affected` | integer ≥ 0 | yes | Distinct users. |
| `sample_stack_trace` | string (multiline) | yes | Primary stack trace, truncated at 4KB to satisfy log-atomicity. |
| `device_breakdown` | array | yes | Per-device `{device, count}`. Empty array allowed. |
| `os_breakdown` | array | yes | Per-OS `{os_version, count}`. Empty array allowed. |
| `linked_tasks` | array of UUIDv7 | yes | Tasks addressing this crash. Bidirectional with `task.links.crashes`. |
| `linked_feedback` | array of UUIDv7 | yes | Feedback records correlated to this crash. Bidirectional with `feedback.linked_crashes`. |
| `fixed_in` | object | yes | `{release_id, commit_sha, verified_no_regression_for_builds}`. Null release_id / commit_sha while unresolved. |
| `propagation` | object | no | Public-safe propagation annotations for chain state, worker prompts, commit bodies, build summaries, release notes, and post-release closeout. Optional; absence means no chain propagation has happened yet. |
| `notes` | string \| null | yes | Triage commentary. |

### Propagation object (1.1.0)

`propagation` is the bridge between private crash metadata and the public chain/release workflow:

| Field | Type | Required | Notes |
|---|---|---|---|
| `chain_run_id` | string \| null | no | Chain-run UUID that first carried the crash fix. |
| `issue_numbers` | array of integers | no | Public GitHub issues or PRs that mention this crash using the public-safe projection. |
| `commit_shas` | array of strings | no | Commit SHAs whose body includes `public_label`, `public_crash_url`, build/version context, or `fix_confidence`. |
| `build_numbers` | array of strings | no | TestFlight/App Store build numbers that include the crash fix. |
| `release_ids` | array of UUIDv7 | no | Release artifacts that include the crash fix. |
| `crashlytics_closeout` | enum \| null | no | `annotated` when authenticated tooling posted the closeout, `queued` when a release/build closeout item was recorded for later, `skipped` when intentionally not annotated, `null` when not attempted. |

## Public-safe projection

Crash records are private by default because they may contain stack traces, user impact counts, raw Crashlytics fields, device/OS breakdowns, and session-level context. Public artifacts must use only this projection:

```yaml
crash:
  id: 0190f52b-0000-7100-8ccc-99ff00aa11bb
  public_label: "Crash in filter preset application"
  public_crash_url: "https://console.firebase.google.com/…"
  fix_confidence: fixed
  builds_affected: ["TF-3046", "TF-3047"]
  versions_affected: ["1.11.0", "1.12.0"]
```

Allowed in public GitHub commits, PR descriptions, chain worker prompts, build summaries, release notes, and post-release annotations:

- Crashlytics issue URLs.
- `public_label`.
- `fix_confidence` (`fixed`, `possibly_fixed`, `mitigated`, `duplicate`, `cannot_reproduce`).
- Build and marketing-version context.
- Public GitHub issue/PR numbers and commit SHAs.

Not allowed in public artifacts:

- `sample_stack_trace`, `fingerprint_sha256`, raw event payloads, session identifiers, user identifiers, or private Crashlytics field dumps.
- Device identifiers or per-device/per-OS breakdown rows.
- Free-form `notes` unless a human rewrites them into `public_label`.

When a crash fix moves from intake to chain state, worker prompt, commit body, build summary, or post-release annotation, producers must carry the public-safe projection and preserve the private `crash.id` for internal joins. Multiple crash fixes in one chain remain separate entries; do not collapse them into one generic "crash fixes" label before commit/release composition.

## States

| State | Meaning |
|---|---|
| `ingested` | Just minted by Chiron. |
| `triaged` | Reviewed; labels added; sample trace summarized. |
| `linked` | Task(s) filed to address — `linked_tasks` non-empty. |
| `fixed` | Fix merged; `fixed_in.release_id` set. |
| `regressed` | Post-fix occurrence observed. State returns from `fixed` to `regressed`. |
| `archived` | Stable no-regression for N builds (see `PHASE-5-PLAN.md`). Terminal. |

State transitions emit `crash_state_changed` (new event catalog entry landing with Phase 5).

## Links

- `linked_tasks` — bidirectional with `task.links.crashes`.
- `linked_feedback` — bidirectional with `feedback.linked_crashes`.
- `fixed_in.release_id` — points at the release that shipped the fix.
- `propagation.release_ids` — records every release artifact that carried the public-safe crash fix summary or closeout.

## 2.6 landing caveat

No writer emits crash artifacts in 2.6. This schema is published so Phase 5's Chiron can land writers against a stable contract. The `plans/crashes/` dir is created lazily on first write — no placeholder file in 2.6.

If a downstream consumer needs to read crash artifacts before Phase 5, it must handle the empty-dir case (`ls plans/crashes/` returns nothing).

## History table

| Version | Landed | Changes |
|---|---|---|
| 1.1.0 | 2026-05-18 | Added optional public-safe projection fields (`public_label`, `public_crash_url`, `fix_confidence`) and optional `propagation` annotations for chain, commit, build/release, and Crashlytics closeout tracking. Non-breaking; `min_reader: 1.0.0`. |
| 1.0.0 | 2026-04-22 | Initial landing as a Phase 2.6 placeholder. No writers yet; Phase 5 (Chiron) supplies ingestion. |

## Related

- `PHASE-5-PLAN.md` — Chiron design and Crashlytics integration.
- `schemas/task.md` / `schemas/feedback.md` — linked artifacts.
- `schemas/release.md` — `fixed_in.release_id` target.
- `contracts/events.md` — `crash_state_changed` (Phase 5 catalog entry).
