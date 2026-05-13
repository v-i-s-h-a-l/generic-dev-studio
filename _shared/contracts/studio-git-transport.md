---
name: Studio Git Transport Inventory
description: Inventory of every studio-owned GitHub Git network transport call site, grouped by auth-mode bucket (GitHub HTTPS, explicit SSH, local worktree/clone, non-GitHub recipe fetches), with the migration plan and diagnostics surface that scripts/lib-github-transport.sh must implement.
type: reference
schema_version: 1
---

# Studio Git Transport Inventory

Source issue: `v-i-s-h-a-l/generic-dev-studio#875` (parent arc `#874`).

This contract enumerates every studio-owned Git network transport call site,
the operation it performs, the GitHub endpoint it depends on, and the
auth-mode classification used to plan the migration to a shared
`scripts/lib-github-transport.sh` helper (issue `#876`).

Call sites are classified into four disjoint buckets:

1. **GitHub HTTPS — studio-owned**
   Network transport against `github.com` that the studio is responsible for
   authenticating. These must route through the normalized `github_home`
   credential root (today via `with_login_home_for_github` or `HOME` flips;
   tomorrow via `scripts/lib-github-transport.sh`).
2. **Explicit SSH allowances**
   Transport that may legitimately use SSH (`git@github.com:...`) or other
   non-HTTPS auth surfaces because the operation is opt-in user-driven, an
   isolated test seam, or a deliberate fallback. The shared helper must keep
   a user-controlled override for these.
3. **Local worktree / clone operations**
   `git fetch`, `git clone --no-local`, `git worktree add`, `git push` between
   on-disk paths (chain worktree → issue worktree, refresh-base against an
   already-populated `origin` ref). These do not touch the network and are
   out of scope for the gh-backed helper, but they appear next to network
   transport in the listed scripts and need to be excluded from migration.
4. **Non-GitHub recipe fetches**
   Network transport against repositories named by `recipes/**/<name>.yaml`
   `sources[].upstream`. These are studio-driven but the remote is whatever
   the recipe author published; auth is anonymous HTTPS today. They share
   the diagnostics surface (stale helper, missing `gh`, network partition)
   but route to a third-party host, so they will use the helper's
   `--anonymous` mode rather than the gh-credential path.

Per-script tables list `path:line` references against the chain-runner
worktree commit `5021648` (release `v0.14.0` + #743). Line numbers are
documentation-only — readers should re-grep before editing.

---

## 1. GitHub HTTPS — studio-owned

### `scripts/studio-chain-runner.sh`

| Line | Call | Operation | Auth mode today | Notes |
|---|---|---|---|---|
| 6519 | `with_login_home_for_github git ls-remote --heads origin "$source_branch"` | Resolve `origin/<source-branch>` head SHA before chain launch | normalized `github_home` via `with_login_home_for_github` | Used by `verify_expected_source_sha_or_abort`; retryable_halt classifies failure as `network_partition`. |
| 6522 | `with_login_home_for_github git ls-remote --heads origin "$source_branch"` | Same call re-invoked inside `retryable_halt_details_json` to capture command text in halt record | normalized `github_home` | Diagnostic-only re-invocation; output is the human-readable command captured in halt details. |
| 6544 | `with_login_home_for_github git ls-remote --exit-code --heads origin "$base"` | Live preflight: assert chain `source_branch` exists on origin before any chain work | normalized `github_home` | Wrapped in `run_retryable_or_abort network_partition`. |
| 6550 | `with_login_home_for_github git ls-remote --exit-code --heads origin "$branch"` | Live preflight: assert chain branch does **not** already exist on origin (avoid clobber) | normalized `github_home` | Inverted-truthiness check; used by `live_preflight`. |
| 6563 | `with_login_home_for_github git ls-remote --exit-code --heads origin "$issue_branch"` | Live preflight: assert per-issue branch does not already exist on origin | normalized `github_home` | Same pattern as above for each issue branch. |

Out-of-bucket within this script: line 7234 (`DRY-RUN git clone --no-local`)
is a dry-run *string*, not an execution; line 19 of `lib-chain-git.sh`
performs the real local clone. Both belong to bucket 3.

### `scripts/pr-merge-finalize.sh`

| Line | Call | Operation | Auth mode today | Notes |
|---|---|---|---|---|
| 179 | `with_login_home_for_github git push origin --delete "$head_ref"` | Delete merged feature branch on origin (cleanup after `gh pr merge`) | normalized `github_home` | Sets `cleanup_failed` if both this and the follow-up `ls-remote` say the branch still exists. |
| 182 | `with_login_home_for_github git ls-remote --exit-code --heads origin "$head_ref"` | Probe whether the remote head branch still exists after the delete attempt | normalized `github_home` | Used to disambiguate "delete failed" from "branch already gone." |
| 203 | `with_login_home_for_github git fetch origin "$base_ref"` | Refresh local view of base before mergeability checks | normalized `github_home` | Best-effort; failure is logged but not fatal. |
| 204 | `with_login_home_for_github git fetch origin "$head_ref"` | Refresh local view of PR head before policy gates | normalized `github_home` | Best-effort. |
| 327 | `with_login_home_for_github git fetch --prune origin` | Post-merge prune of remote-tracking refs | normalized `github_home` | Failure sets `cleanup_failed` + `fetch_prune_failed` note. |
| 331 | `with_login_home_for_github git fetch origin "$base_ref"` | Final fetch of the merged base ref before fast-forward | normalized `github_home` | Failure sets `cleanup_failed` + `fetch_base_failed` note. |

Note: line 188 (`gh pr view ...`) and line 241 (`gh pr view ... --jq ...`) are
GitHub API calls already routed through `with_login_home_for_github`; they are
not Git transport but appear inline with the transport calls and document
the same auth root.

### `scripts/manager-release-branch.sh`

| Line | Call | Operation | Auth mode today | Notes |
|---|---|---|---|---|
| 89 | `git -C "$REPO_ROOT" fetch --quiet "$REMOTE" "+refs/heads/*:refs/remotes/$REMOTE/*"` | Mirror remote heads before status / sync / PR checks | **ambient** (no `github_home` normalization) | Called by `fetch_remote()` used in every subcommand. Migration target: route through helper to pick up `gh auth git-credential`. |
| 105 | `git -C "$REPO_ROOT" ls-remote --exit-code --heads "$REMOTE" "$branch"` | `remote_branch_exists` fallback when local remote-tracking ref is absent | **ambient** | Same migration target as above. |
| 246 | `git -C "$REPO_ROOT" push "$REMOTE" "$base_sha:refs/heads/$target"` | Create the release branch on remote without checking it out locally | **ambient** | Mutating push; this is the highest-risk ambient transport in this script. |

### `scripts/studio-tf-push.sh`

| Line | Call | Operation | Auth mode today | Notes |
|---|---|---|---|---|
| 226 | `git push origin "refs/tags/${tag}"` | Publish a TestFlight anchor tag after `git tag -a` | **ambient** | Inside `push_tf_tag()`; called from the TestFlight push subcommand. |
| 997 | `git push -u origin HEAD` | Push the build-number bump commit + branch as part of the TF push preflight | **ambient** | Halt class `STRANDED_RELEASE_STATE` if the push fails after local tag creation. |
| 1255 | `git fetch --tags origin` | Refresh tag refs before `withdraw-tf-tag` rename | **ambient** | Inside the `withdraw-tf-tag` subshell. |
| 1267 | `git push origin "refs/tags/${NEW_TAG}"` | Publish the renamed `*-WITHDRAWN` tag | **ambient** | Mutating push. |
| 1268 | `git push origin ":refs/tags/${OLD_TAG}"` | Delete the original TF tag on origin | **ambient** | Mutating push (delete refspec). |
| 1332 | `git push -u origin HEAD` | Push the App Store source branch before submission | **ambient** | Halt class `prereq` if it fails. |
| 1473 | `git push origin "$TAG"` | Publish the App Store release tag after submission succeeds | **ambient** | Deferred-tag flow from #824 follow-up. |

All `studio-tf-push.sh` transport runs under whatever `HOME` the release host
launched with. Because TF pushes happen on the laptop today (secrets stay
laptop-only per `project_release_substrate_arc`), the ambient root usually
matches the user's interactive `gh auth`. Migration must preserve that
laptop-only constraint while still routing through the helper.

### `scripts/host-preflight.sh`

| Line | Call | Operation | Auth mode today | Notes |
|---|---|---|---|---|
| 72 | `HOME="$github_home" git -C "$REPO" ls-remote --exit-code "$remote_url" HEAD` | Credential-helper proof; exercises the exact `git credential` path later steps rely on | normalized `github_home` via in-line `HOME=` flip (resolved by `studio_context_resolve github-operation`) | This is the *first* studio call that verifies the host has working GitHub Git credentials. Migration must keep this as the canonical proof point — the helper should expose a `preflight` mode that reuses the same diagnostic surface. |

Comment-only references at lines 64 and 72 (`# git ls-remote ...`) document
the contract; they are not transport calls.

### `scripts/lib-chain-git.sh`

This library does not perform GitHub network transport directly. All calls
are local (see bucket 3). It is listed in the parent plan because callers
(`studio-chain-runner.sh`) wrap it with `with_login_home_for_github` when
needed; the library itself stays transport-agnostic.

---

## 2. Explicit SSH allowances

The studio does not currently hard-code any `git@github.com:...` remotes,
but it must keep the door open for two cases:

| Surface | Why SSH may appear | Auth mode | Notes |
|---|---|---|---|
| User project remotes inherited via `task-worktree-setup.sh` | User project may use SSH origin; studio reads but never rewrites | Whatever the user configured (SSH agent / keychain) | `task-worktree-setup.sh` only inspects local refs (`origin/<base>`); no network transport. No migration work required. |
| `STUDIO_BYPASS_PARENT_HOME_FLIP=1` in `lib-studio-context.sh` (line 218) | User-controlled override for intentional isolation tests against the caller's `HOME` (which may have an SSH-only `gh` config) | Caller `HOME` | The shared helper must respect this override and not silently re-flip to `github_home`. |

Acceptance for `#876`: the helper must accept an explicit
`--ssh` / `STUDIO_GIT_TRANSPORT_FORCE_SSH=1` mode and skip the
`gh auth git-credential` configuration when set. The override must emit a
loud stderr audit line, matching the discipline used for other
`STUDIO_BYPASS_*` flags.

---

## 3. Local worktree / clone operations (no GitHub network)

These are local-disk Git operations that appear in the listed scripts but do
not require network auth. They are explicitly out of scope for
`scripts/lib-github-transport.sh`.

| Script | Line | Call | Operation |
|---|---|---|---|
| `scripts/lib-chain-git.sh` | 19 | `git clone --quiet --no-local --branch "$chain_branch" "$chain_worktree" "$issue_worktree"` | Clone chain worktree into per-issue worktree (local path → local path); used by `local-clone` git metadata strategy |
| `scripts/lib-chain-git.sh` | 102, 104, 108 | `git -C "$issue_worktree" fetch "$chain_worktree" ...` and reverse | Local fetch between worktrees during issue integration |
| `scripts/studio-chain-runner.sh` | 7234 | `printf 'DRY-RUN git clone --no-local --branch %q %q %q\n'` | Dry-run echo; not executed |
| `scripts/achilles-refresh-base.sh` | 86 | `git -C "$WORKTREE" fetch origin "$BASE_BRANCH"` | Best-effort fetch of base into existing worktree — network-capable but operates against the ambient `origin` already configured by chain setup; treated as a local convenience because failure is non-fatal and offline mode is supported by design |
| `scripts/task-worktree-setup.sh` | 42, 48 | `git -C "$REPO_ROOT" rev-parse origin/$BASE_BRANCH` / `git branch ... origin/$BASE_BRANCH` | Read local remote-tracking refs only |
| `scripts/manager-release-branch.sh` | 164, 170 | `git worktree add --detach`, `git -C "$wt" merge --no-commit --no-ff` | Local mergeability probe; no network |

**`achilles-refresh-base.sh` placement:** the fetch at line 86 *can* hit the
network, but the script's contract explicitly tolerates `origin` being
absent or stale (offline / no-remote is "not a failure mode") and the
operation runs inside a worker worktree whose `origin` was already proved
reachable by `host-preflight.sh`. Migration to the shared helper is
optional here — the failure mode is already handled. Inventory keeps it in
bucket 3 to avoid expanding the migration scope for a no-op.

---

## 4. Non-GitHub recipe fetches

Recipe-driven transport always points at the `upstream` field of a
`recipes/**/<name>.yaml` source. The remote may or may not be GitHub; the
studio does not own credentials for arbitrary upstreams.

| Script | Line | Call | Operation | Auth mode today | Notes |
|---|---|---|---|---|---|
| `scripts/update-recipes.sh` | 70 | `git ls-remote "https://github.com/$author/$repo.git" HEAD` | Probe upstream default-branch HEAD for drift detection | **anonymous HTTPS** | Upstream `.git` URLs are public; auth is not required today. Helper migration goal: shared diagnostics + `GIT_TERMINAL_PROMPT=0`. |
| `scripts/update-recipes.sh` | 235 | `git -C "$REPO_ROOT" push -u origin "$branch"` | Push the recipe-bump branch back to **the studio's own GitHub repo** before opening a PR | **ambient** | This is technically bucket 1 (studio-owned GitHub push). Called inside `update_one_recipe()` after the recipe bump commit; runs from cron / LaunchAgent so the ambient `gh auth` must be valid. Migration target. |
| `scripts/install-recipe.sh` | 82–83 | `git remote add origin "https://github.com/$author/$repo.git"` + `git fetch -q --depth 1 origin "$sha"` | Vendor a pinned SHA from an upstream skill repo | **anonymous HTTPS** in a throwaway `mktemp` tree | Helper migration goal: route through `--anonymous` mode and surface stale-helper diagnostics if a credential helper redirects auth. |
| `scripts/rollback-recipe.sh` | 88 | `git ls-remote --exit-code "https://github.com/$author/$repo.git" "$rollback_sha"` | Probe whether the rollback target SHA exists upstream | **anonymous HTTPS** | Some servers reject SHA refs; the script falls back to a shallow fetch probe immediately after. |
| `scripts/rollback-recipe.sh` | 91–92 | `git remote add origin ... && git fetch -q --depth 1 origin "$rollback_sha"` | Shallow-fetch probe for the rollback SHA | **anonymous HTTPS** in a throwaway `mktemp` tree | Same migration target as `install-recipe.sh` lines 82–83. |
| `scripts/sync-shared-remote.sh` | 71 | `git clone --depth 1 --branch "$BRANCH" "$REMOTE_URL" "$CACHE_DIR"` | Provision local clone of the private cross-machine sync repo | **ambient** (URL provided by `DEV_STUDIO_SYNC_REMOTE` — typically SSH) | Per script header, the remote is user-configured and never auto-provisioned. Listed here because it is **not** the studio-owned monorepo; auth is whatever the user wired into the env var. The helper must permit this user-driven remote URL to flow through unchanged. |
| `scripts/sync-shared-remote.sh` | 84 | `git -C "$CACHE_DIR" fetch origin "$BRANCH"` | Fetch updates from the private sync remote | **ambient** | Same constraints as above. |
| `scripts/sync-shared-remote.sh` | 121 | `git -C "$CACHE_DIR" push origin "$BRANCH"` | Push self-partition into the private sync remote | **ambient** | Same constraints. |

---

## Migration order for `#876`–`#879`

`#876` (helper) needs to cover the auth modes used in buckets 1 and 4
(anonymous):

- Default mode: HTTPS GitHub remote authenticated via `gh auth git-credential`
  under normalized `github_home`, `GIT_TERMINAL_PROMPT=0`.
- `--anonymous` mode: HTTPS GitHub remote with no credential helper, used by
  recipe fetches against third-party repos.
- `--ssh` mode (user override): preserve `STUDIO_BYPASS_PARENT_HOME_FLIP=1`
  semantics and `STUDIO_GIT_TRANSPORT_FORCE_SSH=1` for intentional SSH /
  isolated-auth testing.

`#877` (migration) sequences the script edits roughly in risk order:

1. `scripts/host-preflight.sh` (proof point; already uses the right root).
2. `scripts/pr-merge-finalize.sh` (already wrapped with `with_login_home_for_github`; mechanical swap).
3. `scripts/studio-chain-runner.sh` (already wrapped; mechanical swap).
4. `scripts/manager-release-branch.sh` (ambient → helper; behavior change).
5. `scripts/studio-tf-push.sh` (laptop-only; keep ambient-equivalent semantics by default, opt-in helper mode).
6. `scripts/update-recipes.sh` (mix of bucket 1 push + bucket 4 probe).
7. `scripts/install-recipe.sh`, `scripts/rollback-recipe.sh` (bucket 4 anonymous).
8. `scripts/sync-shared-remote.sh` (user-configured remote — wrap only the studio-owned diagnostics; do not change credential source).
9. `scripts/lib-chain-git.sh`, `scripts/task-worktree-setup.sh`,
   `scripts/achilles-refresh-base.sh` — no migration; document the local /
   tolerant-fetch placement.

`#878` (tests) targets the fixture `scripts/test-fixtures/874-gh-transport-auth/`
with a stale `credential.helper` config that would route HTTPS auth to a
broken path; the helper must demonstrably override it.

`#879` (docs) keeps `scripts/README.md`, `core/AUTH-PERMISSIONS.md`, and
`_shared/contracts/release-tf-push.md` aligned with the diagnostics and
override names that ship in `#876`.

---

## Diagnostics surface (for the helper)

Every call site above must be able to report at least these failure modes
through the shared helper:

- `gh_missing` — `command -v gh` failed.
- `gh_auth_missing` — `gh auth status` failed under normalized `github_home`.
- `credential_helper_stale` — a `credential.helper` is configured in
  `--get-all` that points at an unreachable / wrong-account path.
- `network_partition` — transport itself failed with no auth signal.
- `ssh_mode_explicit` — the user override is active; transport ran under
  ambient SSH config and no GH credential normalization was attempted.

These names are the contract that `#876` implements and `#878` proves.

---

## References

- Parent plan: `/Users/vishalsingh/.dev-studio/generic-dev-studio/plan-chains/manual-sources/874-gh-transport-auth.md`
- GH wrapper hard rule: `CLAUDE.md` §GitHub CLI home normalization.
- Existing context helpers: `scripts/lib-studio-context.sh`
  (`_studio_context_github_home`, `with_login_home_for_github`).
- Auth surface contract: `core/AUTH-PERMISSIONS.md`.
