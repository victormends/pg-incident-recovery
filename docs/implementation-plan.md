# pg-incident-recovery — Implementation Plan

## Objective

Turn the existing production script (`start_clusters.ps1`) into a public, reusable, Windows-first PostgreSQL recovery tool that:

- starts multiple stopped PostgreSQL services safely after reboot or crash
- classifies failure modes before retrying blindly
- preserves operator state across interruptions and reboots
- gives DBAs a clear summary of what recovered automatically and what still needs manual intervention

This is **not** a greenfield tool. The implementation plan starts from what already exists in the internal script and defines how to extract, sanitize, and harden it into a public repo.

---

## What Already Exists

The current internal script already implements the core recovery engine:

- persistent queue file for unresolved services
- cluster map persistence (`service -> database name`)
- disk free-space guard before startup
- stale `postmaster.pid` cleanup
- mapping of postgres processes back to a data directory
- crash recovery detection by reading recent log lines
- WAL-missing detection using `pg_controldata`
- parallel service startup using `ThreadJob` / `Start-Job`
- retry loop with bounded retries
- special handling for clusters still in automatic recovery
- final summary with recovered / failed / WAL-corrupted clusters

This means the first public version does **not** need new core logic to be credible. The job is to make the current behavior generic, documented, and safe.

---

## Current Script Architecture

The existing script behaves as a 5-stage recovery orchestrator.

### Stage 0 — Guardrails and state initialization

Current behavior:

- waits 30 seconds after boot so the Windows Service Control Manager can settle
- checks free space on a hardcoded data volume
- refuses to proceed below a critical threshold
- creates queue and cluster-map files if missing

Current internal artifacts:

- `failed_clusters.txt`
- `cluster_map.txt`

Public refactor target:

- move hardcoded paths into a config file
- detect the relevant PostgreSQL volume dynamically when possible
- keep persistent state files, but rename them to public-safe names:
  - `state/failed-clusters.txt`
  - `state/cluster-map.txt`

---

### Stage 1 — Service discovery and data directory resolution

Current behavior:

- enumerates Windows services using an environment-specific naming pattern
- inspects service `PathName` via WMI
- extracts `-D <data_dir>` from the service command line
- fills missing queue entries automatically from installed services

Why this matters:

- multi-cluster Windows hosts are common in legacy ERP/on-prem environments
- service names alone are not enough; recovery decisions need the data directory

Public refactor target:

- generalize service matching to configurable patterns instead of a fixed internal prefix
- resolve data directory using one ordered strategy:
  1. queue file cache
  2. service command line `-D`
  3. fallback config mapping

---

### Stage 2 — Preflight classification

Current behavior before starting a cluster:

- cleans or validates `postmaster.pid`
- checks if the PID from `postmaster.pid` is alive
- kills the stale/orphaned process if necessary
- uses `pg_controldata` to detect whether the required WAL file is missing
- short-circuits retries if WAL is missing

This is the core of the script's credibility. It does not just call `Start-Service` in a loop. It classifies what kind of failure it is dealing with.

Public recovery states should be formalized as:

| State | Meaning | Automatic Action |
|---|---|---|
| `ready_to_start` | No blocking condition found | Start immediately |
| `stale_pid` | `postmaster.pid` exists but process is dead | Remove file, then start |
| `crash_recovery` | Process starts but logs show automatic recovery in progress | Wait and monitor |
| `wal_missing` | `pg_controldata` says required WAL file is absent | Mark as fatal, skip retries |
| `disk_critical` | Free space below minimum threshold | Abort entire run |
| `unresolved_datadir` | Service exists but data directory cannot be mapped | Skip and report |

This state machine should be explicit in the public code and README.

---

### Stage 3 — Parallel startup pass

Current behavior:

- batches all clusters in `ready_to_start`
- starts them in parallel using `Start-ThreadJob` when available
- falls back to `Start-Job`
- records which services started cleanly versus which failed immediately

Why this is important:

- this is the business value of the tool
- starting 10–30 clusters sequentially is slow and operationally noisy
- the script collapses multi-hour manual work into one startup wave plus a retry loop

Public refactor target:

- make concurrency configurable (`max_parallel_starts`)
- keep a safe default rather than “all at once”
- log exactly which services were launched in which wave

---

### Stage 4 — Recovery wait path and clean SCM handoff

Current behavior in the original script:

- detects services that failed to report “Running” but have a postgres process alive
- waits for these services in parallel, not sequentially
- checks logs for crash-recovery markers such as:
  - `automatic recovery in progress`
  - `redo starts at`
  - `checkpoint complete`
  - `database system is ready to accept connections`
- detects when the postgres process dies during recovery and classifies that separately from timeout
- after recovery completes, kills the transient process, removes stale PID state, and re-hands control to SCM via `Start-Service`
- only marks the cluster healthy after a clean SCM-managed restart succeeds

This is the most distinctive part of the implementation. It handles the ugly middle state where PostgreSQL is not fully available yet, but is not truly “failed” either, and it normalizes the cluster back into a clean Windows service state instead of merely detecting a healthy postgres process.

Public refactor target:

- document this as a two-phase recovery model:
  1. bring postgres process up
  2. hand clean control back to Windows SCM after crash recovery finishes
- keep the recovery wait phase parallel, matching the original script
- preserve a dedicated `process_died_during_recovery` branch
- keep log regexes configurable, but ship the public example config in English only

---

### Stage 5 — Retry and final summary

Current behavior:

- retries failed services up to a fixed maximum
- never retries `wal_missing` cases
- rewrites the queue file so only unresolved services remain
- prints a summary grouped into:
  - started successfully
  - still failing
  - WAL corruption / missing WAL
  - skipped

This should remain the end-state of v0.1.

Public refactor target:

- preserve this exact operator experience
- add optional machine-readable JSON output later, but keep the human summary first

---

## Public Repo Structure

Proposed public structure:

```text
pg-incident-recovery/
  README.md
  LICENSE
  .gitignore
  scripts/
    pg-incident-recovery.ps1
  docs/
    implementation-plan.md
    architecture.md
    failure-modes.md
  examples/
    cluster-config.example.json
    failed-clusters.example.txt
    cluster-map.example.txt
    sample-summary.txt
```

Notes:

- keep only **one** main script in v0.1
- rename `start_clusters.ps1` to `pg-incident-recovery.ps1`
- include examples so the repo is not “just a script dump”

---

## Configuration Model

The internal script is too hardcoded for public release. Public v0.1 needs a config file.

Suggested `cluster-config.json`:

```json
{
  "service_name_patterns": ["postgresql*"],
  "state_dir": "C:\\pg-incident-recovery\\state",
  "pg_bin_candidates": [
    "C:\\Program Files\\PostgreSQL\\17\\bin",
    "C:\\Program Files\\PostgreSQL\\16\\bin"
  ],
  "disk": {
    "critical_free_gb": 5,
    "warning_free_gb": 10,
    "check_mode": "data_dir_volume"
  },
  "recovery": {
    "max_retries": 5,
    "retry_delay_seconds": 10,
    "recovery_timeout_seconds": 600,
    "recovery_poll_seconds": 10,
    "max_parallel_starts": 4
  },
  "log_patterns": {
    "recovery_in_progress": [
      "automatic recovery in progress",
      "redo starts at"
    ],
    "ready": [
      "database system is ready to accept connections",
      "checkpoint complete"
    ]
  }
}
```

This is enough for v0.1. More configuration than this adds polish, not signal.

---

## Sanitization Plan

Before public release, remove or generalize all employer-specific details.

### Must sanitize

- hardcoded state directories
- hardcoded PostgreSQL binary paths
- hardcoded service naming assumptions
- non-English operator text
- any real database names written to cluster map examples

### Safe to keep conceptually

- queue file persistence
- stale PID cleanup
- WAL-missing detection via `pg_controldata`
- crash recovery wait logic
- summary output model

### Rewrite rule

If a value is environmental, move it to config.
If a string is local to your company, rename it.
If a message is operator-facing, write it in concise English.

---

## Implementation Phases

## Phase 1 — Extract and preserve behavior

Goal: get a public-safe script skeleton without losing any important recovery behavior from the original.

Tasks:

- copy `start_clusters.ps1` into `scripts/pg-incident-recovery.ps1`
- rename variables and messages to English
- remove company names and version-specific assumptions from comments
- keep the recovery logic intact, especially:
  - stale PID cleanup
  - WAL-missing triage
  - parallel first start wave
  - parallel crash-recovery wait phase
  - clean SCM restart after recovery completion
  - explicit `process died during recovery` reporting

Definition of done:

- script reads cleanly as a generic tool
- no employer-specific strings remain
- no hardcoded service prefix remains

---

## Phase 2 — Introduce config file

Goal: eliminate the hardcoded operational assumptions.

Tasks:

- add `cluster-config.json`
- load thresholds, service patterns, retry counts, and state paths from config
- resolve PostgreSQL bin path via config candidates + PATH fallback
- stop assuming one specific data volume is always the relevant disk

Definition of done:

- the tool can run in a different Windows environment without code edits

---

## Phase 3 — Formalize failure-state classification

Goal: make the internal state machine explicit and reviewable.

Tasks:

- separate preflight checks into dedicated functions:
  - `Resolve-DataDirectory`
  - `Test-DiskGuard`
  - `Test-StalePid`
  - `Test-WalRecoveryState`
  - `Test-WalMissing`
- return structured status objects rather than ad hoc strings where possible

Definition of done:

- each service gets one clear classification before startup begins

---

## Phase 4 — Improve operator safety

Goal: reduce the chance of the tool doing the wrong thing fast.

Tasks:

- add `-WhatIf` / dry-run mode
- add explicit warnings around destructive branches
- never automate `pg_resetwal`
- mark `wal_missing` as “restore from backup required” only

Definition of done:

- the tool remains assistive, not dangerous

---

## Phase 5 — Documentation, examples, and parity review

Goal: make the repo legible to external reviewers.

Tasks:

- write README with problem -> approach -> failure modes -> limitations
- include sample queue/state files
- include sample final summary output
- document why persistence matters if the script or OS dies mid-run
- review the public script against the original line-by-line to confirm no major behavior regressions were introduced during sanitization

Definition of done:

- a reviewer can understand the tool without reading all 500+ lines first

---

## Safety Rules for Public v0.1

The first public release should follow these constraints:

- **do not** include automatic `pg_resetwal`
- **do not** include automatic replication slot dropping in v0.1
- **do not** include webhook notifications yet
- **do not** include self-editing service definitions or registry changes
- **do** keep recovery detection, queue persistence, PID cleanup, and bounded retries

This keeps the tool credible and safe.

---

## README Storyline

The README should explain the repo in this order:

1. operational problem: a Windows host with many PostgreSQL services reboots or crashes
2. why manual recovery is slow and error-prone
3. what the tool automates
4. what the tool intentionally refuses to automate
5. how queue persistence works
6. what a real run looks like
7. limitations and supported environment

The repo should feel like: “a real production recovery tool, carefully bounded,” not “hero script that fixes everything.”

---

## Success Criteria for a Tonight-Deployable v0.1

The repo is deployable tonight if all of these are true:

- local folder exists with sane public structure
- implementation plan is written
- one sanitized script file is identified as the basis for the repo
- the repo scope is constrained to Windows PostgreSQL multi-cluster recovery
- no employer-specific names remain in the public-facing plan
- the public script preserves the original script's core differentiators:
  - queue persistence
  - parallel first start wave
  - parallel crash-recovery wait phase
  - WAL-missing triage via `pg_controldata`
  - clean SCM restart after recovery completion

That is enough to justify starting the repo tonight without overpromising the first release.
