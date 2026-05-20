# Security And Operational Safety

This repository is a public, Windows-first PostgreSQL recovery workflow. It is not a managed recovery service and it does not replace operator judgment during a real incident.

## Supported Use

Use this project only in environments where you are authorized to inspect PostgreSQL services, read PostgreSQL data directories and logs, and start or stop Windows services.

Before using it on a new host:

- Review `examples/cluster-config.example.json` and adapt service patterns, PostgreSQL `bin` paths, disk thresholds, and state paths.
- Run with `-DryRun` first.
- Confirm backups and escalation paths before attempting recovery on production data.
- Keep a separate incident log of operator decisions, especially for WAL-missing or disk-critical cases.

## Safety Boundaries

The tool intentionally does not automate high-risk recovery actions such as:

- `pg_resetwal`
- deleting WAL files
- dropping replication slots
- rewriting Windows service definitions
- declaring a cluster healthy after missing-WAL detection

If the tool reports `wal_missing`, treat it as a restore/escalation decision. Do not try to force the cluster online without a separate PostgreSQL recovery review.

## Reporting Security Issues

If you find a security issue in the public code or documentation, open a GitHub issue with enough detail to reproduce the concern without including secrets, customer data, hostnames, passwords, connection strings, or production log excerpts.

For sensitive reports, contact the maintainer privately through the contact information on the GitHub profile instead of posting operational details publicly.

## Data Handling

Do not commit real incident logs, queue files, cluster maps, PostgreSQL data directories, credentials, customer names, hostnames, or screenshots from production environments. Example files in this repository should remain synthetic and generic.
