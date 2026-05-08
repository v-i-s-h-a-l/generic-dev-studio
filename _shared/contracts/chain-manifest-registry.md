---
name: Chain Manifest Registry
schema_version: 1
description: Planned runtime substrate for durable chain manifest persistence, discovery, monitoring, and resume independent of issue worktrees.
type: contract
---

# Chain Manifest Registry

Chain manifests are workflow inputs, not execution byproducts. A manifest that
only exists inside an issue worktree, temporary checkout, or ad hoc local path is
too fragile to serve discovery, monitor sync, resume, or cross-session
continuity. Worktrees are derived from a manifest that already has a
durable local identity.

This contract defines the planned substrate for runtime-persisted manifests. It
does not replace `chain-manifest@1`; it defines where runnable manifests live,
how imported manifests are identified, and which readers use that source.

## Design Options

| Option | Strengths | Weaknesses | Decision |
|---|---|---|---|
| Repo-committed manifests only (`chains/` or `chain-manifests/`) | Reviewable, shareable, branch-versioned, easy to discover from a clone | Cannot represent in-flight local planning before commit; disappears from monitor when a chain starts from a throwaway worktree or explicit path; forces private or experimental chains into public history too early | Keep as reusable shared source, not the only source |
| Local runtime manifests only | Durable across worktree cleanup, private by default, can preserve imported one-off plans with source metadata | Not reviewable by default, can drift from reusable repo manifests, not portable across machines without export/import | Use for active and imported manifests, but do not make it the sole canonical authoring surface |
| Mixed model | Separates reusable templates from local operational truth; allows import of worktree-local manifests; lets persisted run state outlive source paths | Requires source precedence, IDs, archival policy, and migration from repo-only scanning | Adopt this model |

The mixed model has three source layers:

1. Persisted run state: what actually started or resumed.
2. Runtime manifest registry: locally durable manifests that can start future
   runs and feed monitoring until archived.
3. Repo manifests: reusable checked-in templates under `chains/` or
   `chain-manifests/`.

Readers prefer concrete run state over manifests, and runtime manifests over
repo templates, because the monitor and resume flows must reflect what is
happening locally rather than what happens to be checked into a branch.

## Canonical Layout

The per-project registry lives under:

```text
~/.dev-studio/<project>/chain-manifests/
```

Planned layout:

```text
chain-manifests/
  active/
    <manifest-id>/
      manifest.yaml
      source.json
      runs.json
  archived/
    <YYYY>/
      <manifest-id>/
        manifest.yaml
        source.json
        runs.json
  registry.json
```

`manifest.yaml` is the runnable `chain-manifest@1` payload consumed by
`scripts/studio-chain-runner.sh`. `source.json` records provenance and import
policy. `runs.json` records compact run references so cleanup can decide whether
the manifest is still needed without scanning every report body. `registry.json`
is an index for fast discovery; it is a projection from the per-manifest
directories and can be rebuilt.

During migration, existing runtime manifest directories are compatibility
aliases:

```text
~/.dev-studio/<project>/chains/
~/.dev-studio/<project>/.runtime/chains/
~/.dev-studio/<project>/.runtime/manifests/
```

New writers target `chain-manifests/active/`. Readers may scan the legacy paths
until the migration has imported existing manifests and monitor telemetry shows
no active callers depend on them.

## Source Metadata

Every runtime manifest has a source record:

```json
{
  "schema_version": 1,
  "manifest_id": "chain-runtime-state-substrate-00000000-0000-4000-8000-000000000000",
  "status": "active",
  "created_at": "2026-05-09T00:00:00Z",
  "updated_at": "2026-05-09T00:00:00Z",
  "imported_at": "2026-05-09T00:00:00Z",
  "source_kind": "worktree-import",
  "source_path": "/private/runtime/source/path/chain.yaml",
  "source_repo": "v-i-s-h-a-l/generic-dev-studio",
  "source_branch": "feature/example",
  "source_commit": "abcdef1",
  "source_worktree": "/private/runtime/source/worktree",
  "content_sha256": "sha256:...",
  "target_repo_root": "/path/to/target/repo",
  "issue_repo": "owner/repo",
  "chain_names": ["chain-runtime-state-substrate"],
  "retention_class": "default",
  "archive_reason": null
}
```

Required fields are `schema_version`, `manifest_id`, `status`, `created_at`,
`updated_at`, `source_kind`, `content_sha256`, `chain_names`, and either
`issue_repo` in the manifest payload or `issue_repo` in metadata. Local paths in
metadata are private runtime details and must not be copied into public issue or
PR comments.

Recognized `source_kind` values:

| Kind | Meaning |
|---|---|
| `repo` | Copied or indexed from a checked-in manifest. |
| `explicit-path` | Imported from a path supplied directly to the runner. |
| `worktree-import` | Imported from a manifest inside a task or issue worktree. |
| `generated` | Created by a planner or manager workflow before execution. |
| `legacy-runtime` | Migrated from an older runtime manifest directory. |

## Naming And Identity

`manifest_id` is the stable runtime identity. It is not a filesystem path.

Rules:

- Generate IDs as `<slug>-<uuid>`, where `<slug>` comes from the first chain
  name or the manifest basename.
- Store `content_sha256` for dedupe and audit; content hash alone is not the ID
  because a logical manifest can be edited before its first run.
- Preserve the original path in `source_path` only as metadata. It must not be
  required for discovery or resume.
- Store `manifest_ref` in future run `state.json` as
  `runtime:<manifest_id>` for registry-backed manifests or
  `repo:<relative-path>` for repo-only manifests.
- Monitor row source IDs use `manifest_id` for runtime manifests so Slack row
  identity survives path moves and worktree cleanup.

When a runtime manifest changes after runs exist, write a new revision entry or
new manifest ID rather than mutating history in place. Active `state.json`
continues to point at the manifest snapshot that launched that run.

## Import Policy

Runner and manager front doors import before execution:

1. Resolve the user-supplied manifest or chain name.
2. If the manifest already lives in `chain-manifests/active/`, use it in place.
3. If it lives in repo `chains/` or repo `chain-manifests/`, it can run directly
   as a shared manifest. `--auto` and monitor-ready launches also materialize a
   runtime registry copy before creating worktrees.
4. If it lives anywhere else, copy it into the registry and record
   `source_kind`, original path, git metadata when available, content hash,
   target repo root, issue repo, chain names, and import time.
5. Build worktrees from the registry copy or explicit repo manifest, never from
   a task worktree-local path.

Import is idempotent by content hash plus source metadata. A repeated import of
the same unchanged path may reuse the active manifest ID; a changed payload
creates a new revision or new ID.

## Discovery Readers

`/dev-studio manager work-chain`, `scripts/manager-work-chain.sh`, and
`scripts/studio-chain-runner.sh --discover` read sources in this order:

1. `~/.dev-studio/<project>/chain-runs/*/state.json` for resumable or halted
   runs.
2. `~/.dev-studio/<project>/chain-manifests/active/*/manifest.yaml` for
   locally durable runnable manifests.
3. Repo `chains/*.yaml`, `chains/*.yml`, `chain-manifests/*.yaml`, and
   `chain-manifests/*.yml` for reusable shared manifests.
4. Legacy runtime manifest directories during the migration window.

Name resolution accepts a manifest ID, a chain name, a repo-relative path, or an
absolute path. Ambiguous chain names must print candidate manifest IDs and paths
rather than guessing. Bare discovery remains non-mutating.

## Monitor Readers

The chain monitor desired-row builder reads:

1. Persisted run state under `chain-runs/`.
2. Active runtime registry manifests.
3. Repo manifests.
4. Legacy Slack rows only as recovery input.

Source precedence remains:

```text
persisted-run > runtime-manifest > repo-manifest > slack-legacy
```

`persisted-run` rows reflect actual lifecycle and progress. `runtime-manifest`
rows show queued/planned local work even if the source worktree has been
removed. `repo-manifest` rows are available templates. Completed runtime
manifests become `archived` after the same completed-retention policy used by
monitor rows, unless an open halt, decision escrow, or resumable run references
them.

## Resume Semantics

Resume must not require the original manifest path, worktree, or branch to still
exist.

Planned behavior:

- `state.json` stores both the legacy `manifest` path and a future
  `manifest_ref`.
- On `--resume <run_id>`, the runner loads `state.json`, then resolves
  `manifest_ref` to the runtime registry snapshot when present.
- If the source worktree has disappeared, completed issue summaries and
  persisted plan/state still drive integration, skip, or relaunch decisions.
- If a pending issue needs a fresh worktree, create it from the chain branch and
  manifest snapshot recorded by the run, not from the original worktree-local
  manifest path.
- If both the registry snapshot and enough persisted run plan data are missing,
  fail loud with a typed halt reason such as `manifest_snapshot_missing`; do not
  silently fall back to a same-named repo manifest.
- If the chain branch disappeared but the source branch and manifest snapshot
  remain, the runner is allowed to recreate the chain branch only when the
  existing run state proves no integrated local commits would be lost. Otherwise
  it must halt for operator review.

## Archival And Cleanup

Runtime manifests start in `active/` and move to `archived/<YYYY>/` when all
referencing runs are terminal and past the configured retention window.

Archive, do not delete, when:

- all referenced runs completed and the monitor completed-retention window has
  elapsed;
- a manifest is superseded by a newer runtime import;
- an imported manifest has no run references and has not been touched past the
  orphan-import grace period.

Keep active when:

- any run is running, paused, blocked, halted, or has open decision escrow;
- any issue in the manifest is not terminal;
- a monitor row still needs to show queued local work.

Deletion is a separate explicit cleanup action. It must never remove repo
manifests, source worktrees, branches, or private run reports as a side effect.

## Migration Path

1. Add registry path helpers that resolve
   `~/.dev-studio/<project>/chain-manifests/` through the existing project-root
   resolution layer.
2. Teach discovery to scan `chain-manifests/active/` between persisted run
   state and repo manifests.
3. Teach runner start paths to import explicit-path and worktree-local manifests
   before worktree creation, then record `manifest_ref` in `plan.json` and
   `state.json`.
4. Teach monitor sync to read active registry manifests and use manifest IDs for
   runtime source identity while preserving legacy runtime path scans.
5. Backfill imports from legacy runtime manifest directories with
   `source_kind: "legacy-runtime"`.
6. After telemetry shows no active legacy runtime readers, stop writing to the
   compatibility directories and leave read-only import support for one release
   window.

Each step is backwards-compatible: existing repo manifests keep running, and
existing runs can resume from legacy `state.json` while newer runs gain
`manifest_ref`.

## Non-Goals

- Do not replace `chain-manifest@1` or change the `chains[].issues[]` execution
  schema in this substrate plan.
- Do not make Slack, GitHub issues, or PR comments a source of truth for
  manifests.
- Do not auto-commit local runtime manifests into the repo.
- Do not sync runtime registries across machines in this phase.
- Do not store secrets in manifest metadata.
- Do not delete worktrees or branches as part of manifest archival.
