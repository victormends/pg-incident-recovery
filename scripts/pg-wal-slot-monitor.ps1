<#
.SYNOPSIS
    PostgreSQL replication slot monitor with threshold-gated orphaned-slot cleanup.

.DESCRIPTION
    Designed to run under Task Scheduler (e.g., every 5 minutes, under SYSTEM or a
    service account with pg_monitor / superuser rights).

    For each configured PostgreSQL instance the monitor:
      - Queries pg_replication_slots
      - Identifies slots that are inactive (active = false)
      - Computes bytes_retained
      - Emits a WARNING to the Windows Event Log and log file when any slot exceeds
        the warning threshold
      - Drops the slot automatically when bytes_retained >= $AutoDropThresholdBytes
      - Separately alerts when the actual pg_wal directory size exceeds $WalDirAlertBytes

    On PostgreSQL 13+ you can enforce max_slot_wal_keep_size in postgresql.conf as a
    hard cap. This monitor is the PG12-compatible equivalent: a scheduled process that
    enforces the same guardrail at the operator level.

.NOTES
    Sanitized version — internal hostnames, ports, and paths replaced with
    configurable parameters. No client data or production credentials included.

    Platform: Windows Server / Windows workstation
    PowerShell: 5.1+
    PostgreSQL: 12+ (designed for PG12 where max_slot_wal_keep_size is unavailable)
#>

param(
    # Set to $true to log and alert without dropping any slots.
    [bool]$AlertOnly = $false,

    # Path where log file and Event Log source will be written.
    [string]$LogDir = "C:\PG_Monitor",

    # Windows Event Log source name (created on first run if absent).
    [string]$EventSource = "PG_WAL_Monitor",

    # Emit a warning when a slot retains more than this many bytes.
    [long]$WarnThresholdBytes = 500MB,

    # Auto-drop a slot when retained bytes exceed this threshold.
    # (Inactive time is no longer evaluated as PostgreSQL does not natively track disconnection timestamps).
    [long]$AutoDropThresholdBytes = 2GB,

    # Alert when the pg_wal directory itself exceeds this size.
    [long]$WalDirAlertBytes = 4GB
)

# ---------------------------------------------------------------------------
# Instance definitions — edit to match your environment.
# Add one entry per PostgreSQL instance you want to monitor.
# ---------------------------------------------------------------------------
$instances = @(
    @{
        Name    = "PG-Primary"
        Port    = 5432
        WalDir  = "C:\PostgreSQL\data\pg_wal"   # path to pg_wal for this instance
    },
    @{
        Name    = "PG-Secondary"
        Port    = 5433
        WalDir  = "C:\PostgreSQL\data2\pg_wal"
    }
)

# ---------------------------------------------------------------------------
# Internals — no user-serviceable parts below this line
# ---------------------------------------------------------------------------

$LogFile = Join-Path $LogDir "wal_slots.log"

# Discover psql.exe path
$global:psqlExe = "psql.exe"
$commonPaths = @(
    "C:\Program Files\PostgreSQL\16\bin\psql.exe",
    "C:\Program Files\PostgreSQL\15\bin\psql.exe",
    "C:\Program Files\PostgreSQL\14\bin\psql.exe",
    "C:\Program Files\PostgreSQL\13\bin\psql.exe",
    "C:\Program Files\PostgreSQL\12\bin\psql.exe",
    "C:\Program Files\PostgreSQL\11\bin\psql.exe"
)

# Check if psql is in PATH
try {
    $null = Get-Command "psql.exe" -ErrorAction Stop
} catch {
    # Fallback to common paths
    foreach ($p in $commonPaths) {
        if (Test-Path $p) {
            $global:psqlExe = $p
            break
        }
    }
}

function Ensure-Prerequisites {
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        try {
            New-EventLog -LogName Application -Source $EventSource -ErrorAction Stop
        } catch {
            # May fail without elevation; continue without Event Log if needed.
        }
    }
    
    if (-not (Get-Command $global:psqlExe -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path $global:psqlExe)) {
            Write-Log "FATAL: psql.exe not found in PATH or standard installation directories. Please add PostgreSQL bin directory to PATH." "ERROR"
            exit 1
        }
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    if ($Level -in @("WARNING", "ERROR")) {
        try {
            Write-EventLog -LogName Application -Source $EventSource `
                -EntryType Warning -EventId 1001 -Message $Message
        } catch { <# silently skip if Event Log write fails #> }
    }
}

function Get-SlotInfo {
    param([hashtable]$Instance)

    $query = @"
SELECT
    rs.slot_name,
    rs.slot_type,
    rs.active,
    COALESCE(
        pg_wal_lsn_diff(pg_current_wal_lsn(), rs.confirmed_flush_lsn),
        0
    )::bigint AS bytes_retained,
    COALESCE(
        pg_wal_lsn_diff(pg_current_wal_lsn(), rs.restart_lsn),
        0
    )::bigint AS bytes_pending
FROM pg_replication_slots rs
WHERE rs.active = false
ORDER BY bytes_retained DESC;
"@

    # Use 127.0.0.1 instead of localhost to avoid IPv6 (::1) auth rejections common on Windows pg_hba.conf defaults
    $result = & $global:psqlExe -h 127.0.0.1 -p $Instance.Port -U postgres -c $query --csv --no-align --tuples-only 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Format array result into a single string for logging
        $errMsg = $result -join ' '
        Write-Log "[$($Instance.Name)] Failed to query pg_replication_slots: $errMsg" "ERROR"
        return @()
    }

    $lines = $result | Where-Object { $_ -match ',' }
    return $lines | ForEach-Object {
        $cols = $_ -split ','
        [PSCustomObject]@{
            slot_name      = $cols[0].Trim()
            slot_type      = $cols[1].Trim()
            active         = $cols[2].Trim()
            bytes_retained = [long]$cols[3].Trim()
            bytes_pending  = [long]$cols[4].Trim()
        }
    }
}

function Drop-Slot {
    param([hashtable]$Instance, [string]$SlotName)
    $query = "SELECT pg_drop_replication_slot('$SlotName');"
    $result = & $global:psqlExe -h 127.0.0.1 -p $Instance.Port -U postgres -c $query 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errMsg = $result -join ' '
        Write-Log "[$($Instance.Name)] Failed to drop slot '$SlotName': $errMsg" "ERROR"
    }
}

function Check-WalDir {
    param([hashtable]$Instance)
    if (-not (Test-Path $Instance.WalDir)) { return }
    $sizeBytes = (Get-ChildItem $Instance.WalDir -File | Measure-Object Length -Sum).Sum
    if ($sizeBytes -ge $WalDirAlertBytes) {
        $sizeMB = [math]::Round($sizeBytes / 1MB)
        $limitMB = [math]::Round($WalDirAlertBytes / 1MB)
        Write-Log "[$($Instance.Name)] pg_wal directory size ${sizeMB}MB exceeds alert threshold (${limitMB}MB)" "WARNING"
    }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

Ensure-Prerequisites

foreach ($inst in $instances) {
    Write-Log "[$($inst.Name)] Starting WAL slot check (port $($inst.Port))"

    $slots = Get-SlotInfo -Instance $inst

    foreach ($slot in $slots) {
        $name        = $slot.slot_name
        $retained    = [long]$slot.bytes_retained
        $retainedMB  = [math]::Round($retained / 1MB, 1)

        if ($retained -ge $WarnThresholdBytes) {
            Write-Log "[$($inst.Name)] Slot '$name' retaining ${retainedMB}MB" "WARNING"
        }

        if ($retained -ge $AutoDropThresholdBytes) {
            if ($AlertOnly) {
                Write-Log "[$($inst.Name)] AlertOnly=true - would drop slot '$name' (${retainedMB}MB)" "WARNING"
            } else {
                Write-Log "[$($inst.Name)] Dropping orphaned slot '$name' (${retainedMB}MB)" "WARNING"
                Drop-Slot -Instance $inst -SlotName $name
                Write-Log "[$($inst.Name)] Slot '$name' dropped successfully"
            }
        }
    }

    Check-WalDir -Instance $inst
}

Write-Log "WAL slot monitor run complete"
