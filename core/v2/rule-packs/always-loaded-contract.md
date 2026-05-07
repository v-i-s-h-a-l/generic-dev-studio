<!-- always-loaded-contract:version=1 -->
<!-- always-loaded-contract:budget-tokens=700 -->

# Minimal Always-Loaded Rule Contract

This bootstrap floor is loaded for every Studio task so hosts can route work,
find required packs, and fail before unsafe side effects. Detailed guidance
belongs in selected packs.

<!-- always-loaded-contract:rules -->
## Always Loaded Rules

The always-loaded surface is limited to:

- **Worktree isolation:** write only inside the owned worktree or declared
  runtime roots.
- **Privacy/public-output boundary:** private runtime details stay under
  `~/.dev-studio/**` or `.studio/**`; public outputs use abstract summaries.
- **GitHub wrapper:** assistant GitHub CLI calls use `scripts/studio-gh.sh` or
  the v2 successor wrapper; raw `gh` is not load-bearing.
- **Rule-pack loading obligation:** before action, resolve packs from manifest,
  profile, role or mode, classifier, and manual override.
- **Script-enforcement obligation:** mechanical gates that can be checked by
  repo scripts must be enforced by scripts or fixtures.
- **User-controlled override requirement:** every blocking rule must name an
  operator-owned bypass. Assistants do not self-bypass.

<!-- always-loaded-contract:exclusions -->
## Not Always Loaded

These topics must live behind selected rule packs or on-demand references:

- Detailed iOS artifact policy.
- Worker-routing scoring and model-selection heuristics.
- Release, TestFlight, App Store, Slack, and signing routing.
- Cleanup TTL details and janitor timing.
- Full git policy beyond the isolation and wrapper floor above.
- Full telemetry field lists, event catalogs, and reporting schemas.

<!-- always-loaded-contract:lookup-order -->
## Rule-Pack Lookup Order

Resolve required packs in this order. Later sources are additive unless they
explicitly remove or override a pack:

1. Task or chain manifest.
2. Project profile.
3. Role or mode contract.
4. Classifier output.
5. Manual operator override.

<!-- always-loaded-contract:missing-invalid-pack -->
## Missing or Invalid Packs

If a required pack is missing, unreadable, invalid, over budget, or unsupported,
the role must stop before side effects and return a blocked result. The result
names the pack, lookup source, validation failure, retry action, and
operator-owned override if one exists. Optional packs may be skipped only when
the resolver records why.

<!-- always-loaded-contract:budget -->
## Context Budget

Target: 700 estimated tokens using `chars / 4`. Raising it requires a test
update and commit-message rationale.

<!-- always-loaded-contract:non-goals -->
## Non-Goals

This document does not implement rule-pack resolution, rewrite host adapters, or
define pack metadata. Those surfaces are owned by later selective loading work.
