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

Runtime persistence and worktree-independent discovery are planned in
`_shared/contracts/chain-manifest-registry.md`. Repo `chains/` remains a shared
manifest source, while the planned local registry under
`~/.dev-studio/<project>/chain-manifests/` becomes the durable source for
imported or in-flight manifests before worktrees are created.

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
    base_ref: main
    # source_branch, target_base, and base remain accepted as v1 aliases of base_ref.
    independent: false
    # parent_branch is the v2 alias used by stacked chains; conflicts with base_ref are rejected.
    branch: feature/release-bearing-chain-policy
    base_sha: 0190f52a90007f018aaa77fe8fa99bbb00000000
    # expected_source_sha and source_sha remain accepted as v1 aliases of base_sha.
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
| `chains[].base_ref` | no | resolves to `parent_branch`, `source_branch`, `target_base`, or `base` if absent; generated plans choose known feature branch, newest release branch, then default base | v2 canonical name for the chain's source/PR base branch. Chain branches are created from `origin/<base_ref>`, issue branches are created from the chain branch, and PR creation uses this branch as `--base`. |
| `chains[].base_sha` | no | resolves to `parent_sha`, `expected_source_sha`, or `source_sha` if absent | v2 canonical name for the stale-source guard SHA. When present, mechanical gates and PR finalization verify the selected base branch still points at this SHA. `manager plan-chain` records the current `origin/<base_ref>` SHA here on generation. |
| `chains[].parent_branch` | no | - | v2 alias of `base_ref` for chains stacked on a parent chain. Must not be set when `independent` is `true`. If both `parent_branch` and `base_ref` (or any v1 source alias) are present, they must name the same branch — otherwise the runner rejects the manifest as ambiguous. |
| `chains[].parent_sha` | no | - | v2 alias of `base_sha` for stacked chains. Conflicting `parent_sha` and `base_sha` (or v1 SHA aliases) produce a typed manifest/preflight failure. |
| `chains[].independent` | no | `false` | When `false`, the chain is stacked on the selected parent/source branch and must carry parent branch metadata. When `true`, the chain has no parent-chain dependency and `parent_branch`/`parent_sha` must not be set; the runner still uses `base_ref` for PR targeting. |
| `chains[].source_branch` | no | generated plan default | v1 alias of `base_ref`. Conflicts with `base_ref`/`parent_branch`/`target_base`/`base` produce a typed manifest/preflight failure. |
| `chains[].base` | no | generated plan default | v1 alias of `base_ref`. Conflicts with `base_ref`/`parent_branch`/`source_branch`/`target_base` produce a typed manifest/preflight failure. |
| `chains[].target_base` | no | - | v1 alias of `base_ref` for generated manifests that use target-base wording. Conflicts produce a typed manifest/preflight failure. |
| `chains[].expected_source_sha` / `chains[].source_sha` | no | - | v1 SHA aliases. Conflicts with `base_sha`/`parent_sha` (or with each other) produce a typed manifest/preflight failure. |
| `chains[].branch` | no | `feature/<name>` | Chain branch. It must not equal the resolved base ref. |
| `chains[].host` | no | `auto` | `auto` resolves to the runner default or `--host`. |
| `chains[].approved_release_id` | no | `null` | Marks the chain as release-bearing. When present, each completed leaf is checked before integration for ancestry back to its launch chain commit and for merge commits introduced in the leaf. |
| `chains[].sync_strategy` | no | `rebase` | Leaf integration strategy. `rebase` preserves existing behavior; `squash` is used only when this field explicitly says `squash`. |
| `chains[].phase_review` | no | `auto` | `required`, `auto`, or `off`. |
| `chains[].checkpoint` | no | `off` | `auto` or `off`. Can be overridden by `--checkpoint`. |
| `chains[].execution_policy` | no | default | Optional execution contract block for build/test affinity, DerivedData scope, local-manager preference, queue wait, retention, and offload economics. See `_shared/contracts/ios-isolated-execution.md`. |
| `chains[].rule_packs` | no | inherited | Chain-scoped selective rule-pack request. |
| `chains[].issues[]` | yes | - | Either an integer issue number or an object with `number`/`issue`, optional `dependencies`/`depends_on`, and optional `rule_packs`. Scalar issue lists are sequential by default. |

## Branch-discipline (v2) precedence and drift

The chain shape carries both v2 branch-discipline fields (`base_ref`, `base_sha`,
`parent_branch`, `parent_sha`, `independent`) and the v1 aliases
(`source_branch`, `base`, `target_base`, `expected_source_sha`, `source_sha`).
The v2 fields are additive — runs that resume across the v1→v2 transition keep
working.

Source/base-ref resolution (highest precedence first):

1. `base_ref`
2. `parent_branch` (treated as the parent chain's branch when `independent` is
   `false`)
3. `source_branch`
4. `target_base`
5. `base`
6. default `main`

SHA resolution (highest precedence first):

1. `base_sha`
2. `parent_sha`
3. `expected_source_sha`
4. `source_sha`
5. unset (no drift check at preflight/launch/resume)

If two fields at different precedence layers carry conflicting values, the
runner rejects the manifest with a typed `manifest_branch_discipline_conflict`
preflight failure rather than silently picking one. The same rule applies when
`independent: true` is paired with a non-empty `parent_branch` or `parent_sha`;
that combination is rejected as ambiguous.

`manager plan-chain` resolves `base_ref` from CLI flags and the surrounding
environment, then records the current `origin/<base_ref>` SHA into the
generated manifest as `base_sha`. If the user supplied an expected SHA via
`--base-sha`/`STUDIO_PLAN_CHAIN_EXPECTED_BASE_SHA`, the resolved SHA must
match — otherwise plan-chain halts with `base_branch_advanced` unless
`STUDIO_BYPASS_CHAIN_BASE_SHA_DRIFT=1` is set as the documented user-controlled
override.

`manager work-chain` / `studio-chain-runner` perform the same drift check at
launch (`live_preflight`) by comparing the recorded `base_sha` against
`origin/<base_ref>`. `studio-chain-runner --resume` re-runs the check after a
pause and emits the same typed halt when drift is detected. The
`STUDIO_BYPASS_CHAIN_BASE_SHA_DRIFT=1` override applies at every layer; it
emits a stderr audit line when set and is never used silently by an assistant.

## Preflight

`manager work-chain` and `scripts/studio-chain-runner.sh` classify the selected
manifest before creating a run. Planning artifacts such as requirement packets
or task graphs are not executable by the issue-backed runner; convert them by
creating or mapping GitHub issues, then write `chains[].issues[]` with those
issue numbers plus the intended `target_repo_root` and `issue_repo`.

When the selected manifest is not a repo-committed shared manifest, the planned
registry substrate imports it into project runtime first and records source
metadata. Worktrees are execution artifacts derived from the selected manifest;
they are not the manifest home.

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
unless the manifest explicitly changes the strategy. Source-branch targeting
does not change the leaf policy: `source_branch` selects the source/PR base,
the chain branch remains the integration lane, and issue branches still launch
from the chain branch.

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
