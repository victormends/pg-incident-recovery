![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Platform](https://img.shields.io/badge/Platform-Windows%20Server-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)

# pg-incident-recovery

A Windows-first PostgreSQL recovery orchestrator for hosts running multiple PostgreSQL services.

This is intentionally a **Windows-first** operational tool, not a cross-platform abstraction. The point of the repo is to encode a real recovery workflow for service-based PostgreSQL clusters on Windows hosts where careful state classification matters more than generic portability.

This tool is designed for the ugly operational case where a server reboots or crashes and several PostgreSQL clusters come back in mixed states: some cleanly stopped, some stuck behind stale `postmaster.pid`, some still replaying WAL, and some permanently blocked because a required WAL file is gone.

The goal is not to "fix PostgreSQL." The goal is to classify each cluster correctly, automate the safe recovery paths, and stop immediately when the failure requires human intervention.

---

## What Problem It Solves

On Windows hosts with multiple PostgreSQL services, recovery after a reboot is rarely one command.

Typical manual workflow:

1. inspect stopped services one by one
2. identify the data directory behind each service
3. clear stale `postmaster.pid` files where safe
4. try to start the service
5. inspect logs to see whether PostgreSQL is recovering or actually failing
6. repeat the process several times as services move through crash recovery

That is slow, repetitive, and easy to get wrong under pressure.

`pg-incident-recovery` automates the safe parts of that workflow:

- discovers stopped PostgreSQL services
- resolves their data directories
- checks disk free space before startup
- clears stale `postmaster.pid` files
- detects missing WAL via `pg_controldata`
- starts clusters in parallel
- waits for clusters in automatic recovery to become healthy
- retries bounded transient failures
- persists unresolved services to a queue file so the run can resume later

---

## What It Intentionally Does Not Automate

This tool is deliberately conservative.

It does **not**:

- run `pg_resetwal` automatically
- delete WAL files automatically
- drop replication slots automatically
- rewrite PostgreSQL service definitions
- claim to recover irrecoverable clusters

If a required WAL file is missing, the tool marks the cluster as fatal and tells the operator to restore from backup. That boundary is intentional.

---

## Recovery States

Each service ends up in one of these categories:

| State | Meaning | Automatic Action |
|---|---|---|
| `ready_to_start` | No blocking condition found | Start immediately |
| `stale_pid` | `postmaster.pid` exists but process is gone | Remove stale PID file, then start |
| `crash_recovery` | PostgreSQL process is alive and logs show automatic recovery | Wait and monitor |
| `wal_missing` | `pg_controldata` shows required WAL segment is absent | Mark fatal, skip retries |
| `disk_critical` | Free space below configured minimum | Abort run |
| `unresolved_datadir` | Service exists but data directory cannot be resolved | Skip and report |

---

## Architecture

The recovery flow is intentionally simple:

```text
discover stopped services
  -> resolve data directory
  -> preflight classify
      -> disk critical? abort
      -> wal missing? mark fatal
      -> stale pid? clear
      -> otherwise ready
  -> parallel start wave
  -> detect clusters in crash recovery
  -> wait / poll logs
  -> bounded retries for transient failures
  -> rewrite unresolved queue file
  -> print final summary
```

---

## Example Configuration

See [`examples/cluster-config.example.json`](examples/cluster-config.example.json).

Important fields:

- `service_name_patterns`: which Windows services to inspect
- `state_dir`: where queue and cluster-map files live
- `cluster_map_probe_user`: PostgreSQL role used for optional cluster-map enrichment
- `pg_bin_candidates`: candidate PostgreSQL `bin` directories
- `disk.critical_free_gb`: abort threshold
- `recovery.max_parallel_starts`: throttle for parallel startup
- `log_patterns`: localized recovery / ready markers

---

## Usage

```powershell
pwsh -File .\scripts\pg-incident-recovery.ps1 -ConfigPath .\examples\cluster-config.example.json
```

Dry run:

```powershell
pwsh -File .\scripts\pg-incident-recovery.ps1 -ConfigPath .\examples\cluster-config.example.json -DryRun
```

The script expects:

- Windows Server or Windows workstation with PostgreSQL services installed
- PowerShell 5.1+
- `pg_controldata.exe` available in one of the configured PostgreSQL bin directories
- optional: `psql.exe` if you want cluster-map enrichment (`service -> database name`)

---

## Persistent State Design

Two small text files make the tool resumable:

- `failed-clusters.txt`
- `cluster-map.txt`

Why this matters:

- if the script is interrupted, unresolved services remain queued
- if the host reboots again mid-recovery, the next run starts with known service -> data directory mappings
- operators do not have to rediscover the same clusters repeatedly during a long incident

Example files:

- [`examples/failed-clusters.example.txt`](examples/failed-clusters.example.txt)
- [`examples/cluster-map.example.txt`](examples/cluster-map.example.txt)

---

## Example Output

See [`examples/sample-summary.txt`](examples/sample-summary.txt).

The summary is grouped by:

- recovered automatically
- still failing
- fatal WAL-missing cases
- skipped services

This is designed for operators first. Machine-readable JSON can come later, but the human summary is the primary interface in v0.1.

---

## Why This Repo Exists

This project comes from a very specific operational reality: PostgreSQL incident response on Windows hosts with multiple clusters, limited standardization, and no room for trial-and-error during production recovery.

Most public PostgreSQL tooling assumes Linux, single-cluster hosts, or cloud-managed environments. That leaves a real gap for on-prem Windows environments where the right move is not "kubectl restart" or "replace the instance," but careful classification of each individual PostgreSQL service.

That is the niche this repo targets.

---

## Current Scope

Public v0.1 scope:

- Windows-only
- service-based PostgreSQL discovery
- one main script
- config-driven thresholds and bin paths
- bounded retries
- safe failure classification

Not in v0.1:

- webhook notifications
- JSON reports
- automatic `ANALYZE`
- replication-slot remediation
- Linux support

---

## Repo Layout

```text
pg-incident-recovery/
  README.md
  LICENSE
  .gitignore
  scripts/
    pg-incident-recovery.ps1
  docs/
    implementation-plan.md
  examples/
    cluster-config.example.json
    failed-clusters.example.txt
    cluster-map.example.txt
    sample-summary.txt
```

---

## Safety Notes

- Always review the `-DryRun` behavior before pointing the script at a new host.
- Treat `wal_missing` as a restore decision, not an automation opportunity.
- Low-disk aborts are intentional: starting a cluster on an exhausted volume can worsen the incident.
- Localized PostgreSQL logs are real. If your host logs in a different language, update the regex patterns in config.

---

## License

MIT
