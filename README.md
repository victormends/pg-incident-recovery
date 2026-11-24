![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Platform](https://img.shields.io/badge/Platform-Windows%20Server-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)

# pg-incident-recovery

A Windows PowerShell PostgreSQL recovery orchestrator for hosts running multiple PostgreSQL services.

This is intentionally a Windows PowerShell operational tool, not a cross-platform abstraction. The point of the repo is to encode a real recovery workflow for service-based PostgreSQL clusters on Windows hosts where careful state classification matters more than generic portability.

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
- rewrite PostgreSQL service definitions
- claim to recover irrecoverable clusters

Replication slot cleanup is handled by the companion script `pg-wal-slot-monitor.ps1` (see below), which is a separate concern from crash recovery.

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

Ensure your PowerShell execution policy permits running local scripts (for example, `RemoteSigned` in `CurrentUser` scope), then run from Windows PowerShell 5.1+ (`powershell`) or PowerShell 7+ (`pwsh`):

```powershell
powershell -NoProfile -File .\scripts\pg-incident-recovery.ps1 -ConfigPath .\examples\cluster-config.example.json -DryRun
```

Live execution (after reviewing `-DryRun` output):

```powershell
powershell -NoProfile -File .\scripts\pg-incident-recovery.ps1 -ConfigPath .\examples\cluster-config.example.json
```

The script expects:

- Windows Server or Windows workstation with PostgreSQL services installed
- Windows PowerShell 5.1+ (or PowerShell 7+ with `pwsh`)
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

## Origin & Field Results

This tool originated while supporting on-prem multi-cluster Windows PostgreSQL hosts running ~30 database services per host.

In the original environment:

- wave-based parallel startup with stale `postmaster.pid` cleanup and WAL pre-checks cut full-host post-crash recovery from `~3h` to `<5 min`
- deploying `pg-wal-slot-monitor.ps1` alongside `max_slot_wal_keep_size` (on PostgreSQL 13+) eliminated recurring WAL disk exhaustion where deployed

These field timings reflect the original production support environment and are not reproduced by the standalone mock tests in this repository.

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
- Linux support

---

## Companion: WAL Replication Slot Monitor

[`scripts/pg-wal-slot-monitor.ps1`](scripts/pg-wal-slot-monitor.ps1) is a separate
Task Scheduler script that addresses a different failure mode: **orphaned replication
slots accumulating WAL indefinitely** after a subscriber disconnects or is decommissioned.

This is the PG12-compatible equivalent of `max_slot_wal_keep_size` (available only on
PG13+). It:

- queries `pg_replication_slots` left-joined to `pg_stat_replication`
- computes bytes retained per inactive slot
- emits warnings to Windows Event Log and a log file when retention exceeds a threshold
- drops orphaned slots automatically when retention exceeds a threshold
- separately alerts if the `pg_wal` directory itself exceeds a size limit
- exposes an `$AlertOnly` switch for read-only monitoring without any destructive action

**When to use it:**

| PostgreSQL version | Recommended approach |
|---|---|
| PG12 | Schedule `pg-wal-slot-monitor.ps1` every 5 minutes under Task Scheduler |
| PG13+ | Set `max_slot_wal_keep_size` in `postgresql.conf`; optionally keep the monitor as an alert layer |

See [`examples/wal-replication-config.example.conf`](examples/wal-replication-config.example.conf)
for the annotated WAL/replication configuration context this monitor was designed to operate against.

---

## Repo Layout

```text
pg-incident-recovery/
  README.md
  RELEASING.md
  SECURITY.md
  LICENSE
  .gitignore
  scripts/
    pg-incident-recovery.ps1
    pg-wal-slot-monitor.ps1
  tests/
    test-recovery.ps1
  docs/
    linux-parity.md
  examples/
    cluster-config.example.json
    failed-clusters.example.txt
    cluster-map.example.txt
    sample-summary.txt
    wal-replication-config.example.conf
```

---

## Testing & Verification

Run the offline unit test suite on Windows PowerShell 5.1 (or `pwsh` on PowerShell 7+), assuming an execution policy that allows local scripts (e.g. `RemoteSigned`):

```powershell
powershell -NoProfile -File .\tests\test-recovery.ps1
```

For Linux PostgreSQL hosts sharing the same WAL / replication-slot diagnostics, see [`docs/linux-parity.md`](docs/linux-parity.md).

---

## Safety Notes

- Always review the `-DryRun` behavior before pointing the script at a new host.
- Treat `wal_missing` as a restore decision, not an automation opportunity.
- Low-disk aborts are intentional: starting a cluster on an exhausted volume can worsen the incident.
- Localized PostgreSQL logs are real. If your host logs in a different language, update the regex patterns in config.

See [`SECURITY.md`](SECURITY.md) for the public security and operational-safety policy, and [`RELEASING.md`](RELEASING.md) for release verification steps.

---

## License

MIT
