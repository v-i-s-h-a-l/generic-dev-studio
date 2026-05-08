# cleanup-retention Summary

Load for runtime artifacts, chain cleanup, retention, and janitor behavior.
Keep private runtime files under `.studio` or `~/.dev-studio/**`, avoid
committing disposable artifacts, and preserve required summaries before cleanup.
For scoped iOS roots, use retention classes and redacted janitor telemetry
instead of deleting outside studio-owned artifact roots.
