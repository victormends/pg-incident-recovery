<#
.SYNOPSIS
    PostgreSQL replication slot monitor with threshold-gated orphaned-slot cleanup.

.DESCRIPTION
    Designed to run under Task Scheduler (e.g., every 5 minutes, under SYSTEM or a
    service account with pg_monitor / superuser rights).

    For each configured PostgreSQL instance the monitor:
      - Queries pg_replication_slots (PG12+)
      - Identifies inactive slots (active = false) and tracks first-seen-inactive UTC timestamps
      - Computes bytes_retained and elapsed inactive minutes across runs
      - Emits a WARNING to the Windows Event Log and log file when retention exceeds WarnThresholdBytes
      - Drops the slot automatically when retained bytes exceed AutoDropThresholdBytes
        (and inactive minutes >= AutoDropInactiveMinutes when configured > 0)
      - Separately alerts when the actual pg_wal directory size exceeds WalDirAlertBytes

    On PostgreSQL 13+ you can enforce max_slot_wal_keep_size in postgresql.conf as a
    hard cap. This monitor is the PG12-compatible equivalent plus an explicit alerting layer.

.NOTES
    Sanitized version — internal hostnames, ports, and paths replaced with
    configurable parameters. No client data or production credentials included.

    Platform: Windows Server / Windows workstation
    PowerShell: 5.1+ (compatible with Windows PowerShell 5.1 and PowerShell 7+)
    PostgreSQL: 12+
#>

param(
    # Set to $true to log and alert without dropping any slots.
    [bool]$AlertOnly = $false,

    # Path where log file, persistent slot state, and Event Log source are written.
    [string]$LogDir = "C:\PG_Monitor",

    # Windows Event Log source name (created on first run if absent).
    [string]$EventSource = "PG_WAL_Monitor",

    # Target PostgreSQL host and role (override via parameters; authenticate via SSPI / .pgpass / PGPASSWORD).
    [string]$PgHost = "127.0.0.1",
    [string]$PgUser = "postgres",

    # Emit a warning when a slot retains more than this many bytes.
    [long]$WarnThresholdBytes = 500MB,

    # Auto-drop a slot when retained bytes exceed this threshold.
    [long]$AutoDropThresholdBytes = 2GB,

    # Optional minimum continuous inactive duration (in minutes) tracked across runs via state JSON.
    # Leave 0 to gate purely on AutoDropThresholdBytes.
    [int]$AutoDropInactiveMinutes = 0,

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
        WalDir  = "C:\PostgreSQL\data\pg_wal"
    },
    @{
        Name    = "PG-Secondary"
        Port    = 5433
        WalDir  = "C:\PostgreSQL\data2\pg_wal"
    }
)

$LogFile = Join-Path $LogDir "wal_slots.log"
$StateFile = Join-Path $LogDir "slot_inactive_since.json"
$global:psqlExe = "psql.exe"

function Resolve-PsqlExecutable {
    param(
        [string[]]$CommonPaths = @(
            "C:\Program Files\PostgreSQL\17\bin\psql.exe",
            "C:\Program Files\PostgreSQL\16\bin\psql.exe",
            "C:\Program Files\PostgreSQL\15\bin\psql.exe",
            "C:\Program Files\PostgreSQL\14\bin\psql.exe",
            "C:\Program Files\PostgreSQL\13\bin\psql.exe",
            "C:\Program Files\PostgreSQL\12\bin\psql.exe",
            "C:\Program Files\PostgreSQL\11\bin\psql.exe"
        )
    )

    foreach ($candidate in @("psql.exe", "psql")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    foreach ($p in $CommonPaths) {
        if (Test-Path -LiteralPath $p) {
            return $p
        }
    }

    return $null
}

function Test-ValidSlotName {
    param([string]$SlotName)

    if ([string]::IsNullOrWhiteSpace($SlotName)) {
        return $false
    }
    return ($SlotName -cmatch '^[a-z0-9_]{1,63}$')
}

function Ensure-Prerequisites {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        try {
            New-EventLog -LogName Application -Source $EventSource -ErrorAction Stop
        } catch {
            # May fail without elevation; continue without Event Log if needed.
        }
    }

    $resolved = Resolve-PsqlExecutable
    if (-not $resolved) {
        Write-Log "FATAL: psql executable not found in PATH or standard PostgreSQL directories." "ERROR"
        throw "psql executable not found"
    }
    $global:psqlExe = $resolved
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Path = $LogFile
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $Path -Value $line
    if ($Level -in @("WARNING", "ERROR")) {
        try {
            Write-EventLog -LogName Application -Source $EventSource `
                -EntryType Warning -EventId 1001 -Message $Message
        } catch {
            # Skip silently when running non-elevated or in CI containers.
        }
    }
}

function ConvertFrom-SlotCsvLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    $cols = $Line -split ','
    if ($cols.Count -lt 5) {
        return $null
    }

    $slotName = $cols[0].Trim()
    if (-not $slotName -or $slotName -eq 'slot_name') {
        return $null
    }

    [long]$retained = 0
    [long]$pending = 0
    [void][long]::TryParse($cols[3].Trim(), [ref]$retained)
    [void][long]::TryParse($cols[4].Trim(), [ref]$pending)

    $activeVal = $cols[2].Trim().ToLowerInvariant()
    $isActive = ($activeVal -eq 't' -or $activeVal -eq 'true')

    return [PSCustomObject]@{
        slot_name      = $slotName
        slot_type      = $cols[1].Trim()
        active         = $isActive
        bytes_retained = $retained
        bytes_pending  = $pending
    }
}

function Read-InactiveState {
    param([string]$Path)

    $state = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $state
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $state
        }
        $parsed = $raw | ConvertFrom-Json
        foreach ($prop in $parsed.PSObject.Properties) {
            $state[$prop.Name] = [string]$prop.Value
        }
    } catch {
        Write-Warning "Failed to parse slot state file '$Path'; starting with empty inactive state."
    }

    return $state
}

function Write-InactiveState {
    param(
        [string]$Path,
        [hashtable]$State
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $ordered = [ordered]@{}
    foreach ($key in ($State.Keys | Sort-Object)) {
        $ordered[$key] = $State[$key]
    }
    $ordered | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Update-InactiveState {
    param(
        [hashtable]$State,
        [string]$InstanceName,
        [object[]]$ObservedSlots,
        [datetime]$UtcNow = [datetime]::UtcNow
    )

    $observedKeys = @{}
    $durations = @{}

    foreach ($slot in $ObservedSlots) {
        if (-not $slot -or $slot.active) {
            continue
        }
        $key = "${InstanceName}:$($slot.slot_name)"
        $observedKeys[$key] = $true

        if (-not $State.ContainsKey($key)) {
            $State[$key] = $UtcNow.ToUniversalTime().ToString("o")
        }

        $firstSeen = [datetime]::Parse(
            $State[$key],
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $elapsed = ($UtcNow.ToUniversalTime() - $firstSeen).TotalMinutes
        $durations[$slot.slot_name] = [math]::Max(0.0, $elapsed)
    }

    $prefix = "${InstanceName}:"
    foreach ($existingKey in @($State.Keys)) {
        if ($existingKey.StartsWith($prefix) -and -not $observedKeys.ContainsKey($existingKey)) {
            $State.Remove($existingKey)
        }
    }

    return $durations
}

function Get-SlotAction {
    param(
        [long]$RetainedBytes,
        [double]$MinutesInactive,
        [long]$WarnThresholdBytes,
        [long]$AutoDropThresholdBytes,
        [int]$AutoDropInactiveMinutes = 0,
        [bool]$AlertOnly = $false
    )

    $meetsDropSize = ($RetainedBytes -ge $AutoDropThresholdBytes)
    $meetsDropDuration = ($AutoDropInactiveMinutes -le 0) -or ($MinutesInactive -ge $AutoDropInactiveMinutes)

    if ($meetsDropSize -and $meetsDropDuration) {
        if ($AlertOnly) {
            return 'would_drop'
        }
        return 'drop'
    }

    if ($RetainedBytes -ge $WarnThresholdBytes) {
        return 'warn'
    }

    return 'ok'
}

function Format-SlotMessage {
    param(
        [string]$InstanceName,
        [string]$SlotName,
        [long]$RetainedBytes,
        [double]$MinutesInactive,
        [string]$Action
    )

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $retainedMB = [string]::Format($inv, "{0:F1}", ($RetainedBytes / 1MB))
    $inactiveFormatted = [string]::Format($inv, "{0:F1}", $MinutesInactive)

    switch ($Action) {
        'would_drop' {
            return "[$InstanceName] AlertOnly=true - would drop slot '$SlotName' (${retainedMB}MB, ${inactiveFormatted} min inactive)"
        }
        'drop' {
            return "[$InstanceName] Dropping orphaned slot '$SlotName' (${retainedMB}MB, ${inactiveFormatted} min inactive)"
        }
        default {
            return "[$InstanceName] Slot '$SlotName' retaining ${retainedMB}MB (${inactiveFormatted} min inactive)"
        }
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
    $result = & $global:psqlExe -h $PgHost -p $Instance.Port -U $PgUser -d postgres -c $query --csv --no-align --tuples-only 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errMsg = $result -join ' '
        Write-Log "[$($Instance.Name)] Failed to query pg_replication_slots: $errMsg" "ERROR"
        return @()
    }

    $parsed = @()
    foreach ($line in $result) {
        $item = ConvertFrom-SlotCsvLine -Line ([string]$line)
        if ($null -ne $item) {
            $parsed += $item
        }
    }
    return $parsed
}

function Drop-Slot {
    param([hashtable]$Instance, [string]$SlotName)

    if (-not (Test-ValidSlotName -SlotName $SlotName)) {
        throw "Refusing to drop invalid PostgreSQL replication slot name: '$SlotName'"
    }

    $query = "SELECT pg_drop_replication_slot('$SlotName');"
    $result = & $global:psqlExe -h $PgHost -p $Instance.Port -U $PgUser -d postgres -c $query 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errMsg = $result -join ' '
        Write-Log "[$($Instance.Name)] Failed to drop slot '$SlotName': $errMsg" "ERROR"
        return $false
    }
    return $true
}

function Check-WalDir {
    param([hashtable]$Instance)

    if (-not (Test-Path -LiteralPath $Instance.WalDir)) {
        return
    }
    $measure = Get-ChildItem -LiteralPath $Instance.WalDir -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    $sizeBytes = if ($null -ne $measure -and $null -ne $measure.Sum) { [long]$measure.Sum } else { 0 }
    if ($sizeBytes -ge $WalDirAlertBytes) {
        $sizeMB = [math]::Round($sizeBytes / 1MB)
        $limitMB = [math]::Round($WalDirAlertBytes / 1MB)
        Write-Log "[$($Instance.Name)] pg_wal directory size ${sizeMB}MB exceeds alert threshold (${limitMB}MB)" "WARNING"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Ensure-Prerequisites
    $inactiveState = Read-InactiveState -Path $StateFile
    $nowUtc = [datetime]::UtcNow

    foreach ($inst in $instances) {
        Write-Log "[$($inst.Name)] Starting WAL slot check (port $($inst.Port))"

        $slots = @(Get-SlotInfo -Instance $inst)
        $durations = Update-InactiveState -State $inactiveState -InstanceName $inst.Name -ObservedSlots $slots -UtcNow $nowUtc

        foreach ($slot in $slots) {
            $name = $slot.slot_name
            $retained = [long]$slot.bytes_retained
            $minutesInactive = if ($durations.ContainsKey($name)) { [double]$durations[$name] } else { 0.0 }

            $action = Get-SlotAction `
                -RetainedBytes $retained `
                -MinutesInactive $minutesInactive `
                -WarnThresholdBytes $WarnThresholdBytes `
                -AutoDropThresholdBytes $AutoDropThresholdBytes `
                -AutoDropInactiveMinutes $AutoDropInactiveMinutes `
                -AlertOnly $AlertOnly

            if ($action -eq 'warn') {
                $msg = Format-SlotMessage -InstanceName $inst.Name -SlotName $name -RetainedBytes $retained -MinutesInactive $minutesInactive -Action 'warn'
                Write-Log $msg "WARNING"
            }
            elseif ($action -eq 'would_drop') {
                $msg = Format-SlotMessage -InstanceName $inst.Name -SlotName $name -RetainedBytes $retained -MinutesInactive $minutesInactive -Action 'would_drop'
                Write-Log $msg "WARNING"
            }
            elseif ($action -eq 'drop') {
                $msg = Format-SlotMessage -InstanceName $inst.Name -SlotName $name -RetainedBytes $retained -MinutesInactive $minutesInactive -Action 'drop'
                Write-Log $msg "WARNING"
                if (Drop-Slot -Instance $inst -SlotName $name) {
                    $inactiveState.Remove("$($inst.Name):$name")
                    Write-Log "[$($inst.Name)] Slot '$name' dropped successfully"
                }
            }
        }

        Check-WalDir -Instance $inst
    }

    Write-InactiveState -Path $StateFile -State $inactiveState
    Write-Log "WAL slot monitor run complete"
}
