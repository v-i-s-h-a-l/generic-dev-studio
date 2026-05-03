# Studio v2 A9 Rollback Playbook

This playbook is the operator-facing recovery path for A9. It keeps rollback
inside repo artifacts and avoids destructive file moves during the stability
window.

<!-- v2-cutover:rollback-playbook -->
## Trigger

Rollback is appropriate when v2 traffic cannot satisfy one of the parity
scenarios in `core/v2/cutover/manifest.yaml`, when a migrated role contract
cannot resolve, or when the operator reports a v2 traffic regression before A10.

## Steps

1. Set `core/v2/cutover/manifest.yaml` `status` to `rolled-back`.
2. Set `core/v2/skills/dev-studio/forwarders.yaml`
   `transition.cutover_status` to `not-cut-over`.
3. Set every `forwarders[].runtime_cutover` value in
   `core/v2/skills/dev-studio/forwarders.yaml` to `false`.
4. Restore any host-adapter entrypoint text from the archive map if an adapter
   replaced v1 prose during cutover.
5. Run:

```bash
scripts/v2-cutover.sh --validate --allow-rolled-back
scripts/test-fixtures/527-cutover/test-v2-cutover.sh --allow-rolled-back
```

6. Record the rollback event in the chain or release notes and defer A10 until
   the failed parity scenario has a reviewed fix.
