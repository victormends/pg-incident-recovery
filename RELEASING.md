# Releasing `pg-incident-recovery`

## Public Release Checklist

Before tagging a public release, verify:

- The README usage examples match the script parameters in `scripts/pg-incident-recovery.ps1`.
- `examples/cluster-config.example.json` contains only generic paths, service patterns, and thresholds.
- A sanitization check confirms only generic hostnames, service names, and paths appear in configs, examples, and docs.
- The documented safety boundaries still match the implementation: no automatic `pg_resetwal`, WAL deletion, replication-slot remediation, or service-definition rewrite.
- `-DryRun` remains documented before normal execution examples.
- Release notes describe the release as a Windows PowerShell operator-guided recovery tool, not a guaranteed automatic repair system.
