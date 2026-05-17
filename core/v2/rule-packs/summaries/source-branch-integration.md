# source-branch-integration Summary

Load for chain-runner sessions and source-branch integration. Keeps issue
branches isolated, preserves private `.studio` artifacts, commits only scoped
work, records the planned source SHA as provenance, rebases clean non-release
base drift before PR handoff, gates release-bearing source SHA and leaf
ancestry/sync policy strictly, and leaves PR creation, main merges, and issue
closure to the parent runner.
