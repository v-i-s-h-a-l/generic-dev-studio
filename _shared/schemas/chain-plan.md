---
name: Chain Plan Manifest
description: Canonical YAML shape for scripts/studio-chain-runner.sh manifests and the release-bearing chain policy fields projected into run plans.
type: reference
---

# Chain Plan Manifest (`chain-plan@1`)

`scripts/studio-chain-runner.sh` consumes YAML manifests from `chains/*.yaml`
or an explicit manifest path. The structural JSON Schema lives at
`core/v2/schemas/chain-manifest.schema.json`; this file documents the
operational contract the runner enforces when it projects a manifest into
private `plan.json` and `state.json` artifacts.

## Shape

```yaml
schema_version: 1
target_repo_root: /path/to/repo
issue_repo: owner/repo
rule_packs:
  required: [source-branch-integration]
execution_policy:
  build_test_affinity: chain
  derived_data_scope: chain-lane
  prefer_local_manager: true
  max_affinity_queue_wait_sec: 900
  artifact_retention: default
  offload_economics: required
chains:
  - name: release-bearing-chain-policy
    base: main
    branch: feature/release-bearing-chain-policy
    host: auto
    approved_release_id: 0190f52a-9000-7f01-8aaa-77fe8fa99bbb
    sync_strategy: rebase
    phase_review: required
    checkpoint: off
    execution_policy:
      build_test_affinity: chain
      derived_data_scope: chain-lane
      prefer_local_manager: true
      max_affinity_queue_wait_sec: 900
      artifact_retention: default
      offload_economics: required
    rule_packs:
      optional: [privacy]
    issues:
      - 701
      - number: 702
        dependencies: [701]
```

## Fields

| Field | Required | Default | Notes |
|---|---:|---|---|
| `schema_version` | yes | - | Must be `1`. |
| `target_repo_root` | no | manifest checkout or runner repo | Git checkout used for chain worktrees, branch checks, fetches, and cleanup. Relative paths resolve from the manifest directory first, then the runner repo. `STUDIO_CHAIN_TARGET_REPO_ROOT` and `STUDIO_CONTEXT_REPO_ROOT` are env overrides when the manifest is outside a git checkout. |
| `issue_repo` | no | target repo `origin` or studio repo | GitHub `owner/repo` used for issue lookup, PR creation, and issue closure. Project-scoped manifests outside the studio repo must set this explicitly when the target repo remote cannot resolve to GitHub. Aliases: `repo.issue_repo`, `repo.issue`, `repo.slug`, `repo.name_with_owner`. |
| `rule_packs` | no | `[]` | Global selective rule-pack request. Accepts a string, list, or `{required, optional, advisory, disabled}` object. |
| `execution_policy` | no | default | Global execution contract block for future policy resolution. Current runners treat it as manifest data until routing implementation projects it. |
| `chains[].name` | yes | - | Stable chain name; also drives default branch and worktree slugs. |
| `chains[].base` | no | `main` | Explicit PR base. Mechanical gates reject missing or invalid bases in the generated plan. |
| `chains[].branch` | no | `feature/<name>` | Chain branch. It must not equal the base branch. |
| `chains[].host` | no | `auto` | `auto` resolves to the runner default or `--host`. |
| `chains[].approved_release_id` | no | `null` | Marks the chain as release-bearing. When present, each completed leaf is checked before integration for ancestry back to its launch chain commit and for merge commits introduced in the leaf. |
| `chains[].sync_strategy` | no | `rebase` | Leaf integration strategy. `rebase` preserves existing behavior; `squash` is used only when this field explicitly says `squash`. |
| `chains[].phase_review` | no | `auto` | `required`, `auto`, or `off`. |
| `chains[].checkpoint` | no | `off` | `auto` or `off`. Can be overridden by `--checkpoint`. |
| `chains[].execution_policy` | no | default | Optional execution contract block for build/test affinity, DerivedData scope, local-manager preference, queue wait, retention, and offload economics. See `_shared/contracts/ios-isolated-execution.md`. |
| `chains[].rule_packs` | no | inherited | Chain-scoped selective rule-pack request. |
| `chains[].issues[]` | yes | - | Either an integer issue number or an object with `number`/`issue`, optional `dependencies`/`depends_on`, and optional `rule_packs`. Scalar issue lists are sequential by default. |

## Preflight

`manager work-chain` and `scripts/studio-chain-runner.sh` classify the selected
manifest before creating a run. Planning artifacts such as requirement packets
or task graphs are not executable by the issue-backed runner; convert them by
creating or mapping GitHub issues, then write `chains[].issues[]` with those
issue numbers plus the intended `target_repo_root` and `issue_repo`.

## Execution Policy Block

The optional `execution_policy` block is declarative. It makes routing and
artifact expectations visible before later implementation code consumes them;
it does not by itself start builds, select workers, or mutate branches.

```yaml
execution_policy:
  build_test_affinity: chain
  derived_data_scope: chain-lane
  prefer_local_manager: true
  max_affinity_queue_wait_sec: 900
  artifact_retention: default
  offload_economics: required
```

`build_test_affinity: chain` preserves warmed DerivedData and simulator state for
sequential build/test jobs in the same chain. `derived_data_scope: chain-lane`
still requires separate writable cache roots for concurrent lanes. Worker
offload remains eligible only after capability, health, load, queue, lock, and
cost checks pass.

## Release-Bearing Policy

A chain is release-bearing only when `approved_release_id` is present. The
runner keeps non-release-bearing chains on the historical path: issue leaves
are prepared from the chain branch and integrated with `sync_strategy: rebase`
unless the manifest explicitly changes the strategy.

For release-bearing chains, the runner checks each leaf immediately before
integration:

| Gate | Override | Failure |
|---|---|---|
| `release_chain_leaf_ancestry` | `STUDIO_BYPASS_CHAIN_LEAF_ANCESTRY_GATE=1` | Leaf `HEAD` does not descend from the chain commit captured when the issue session started. |
| `release_chain_leaf_merge_commits` | `STUDIO_BYPASS_CHAIN_LEAF_MERGE_COMMIT_GATE=1` | Leaf history contains merge commits after the captured launch commit. |
| `release_chain_sync_strategy` | `STUDIO_BYPASS_CHAIN_SYNC_STRATEGY_GATE=1` | The projected plan contains an unsupported leaf sync strategy. |

These gates append `studio-chain-rule-gate-audit` JSONL rows to the same private
rule-gate audit log as preflight mechanical gates. Overrides are user-controlled
emergency levers and are recorded as `status: "override"`.
