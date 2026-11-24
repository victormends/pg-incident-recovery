#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:Passed++
        Write-Host "[PASS] $Message" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "[FAIL] $Message" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -eq $Expected) {
        $script:Passed++
        Write-Host "[PASS] $Message (expected='$Expected')" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "[FAIL] $Message (expected='$Expected', actual='$Actual')" -ForegroundColor Red
    }
}

# Dot-source both scripts cleanly without triggering host service discovery.
. (Join-Path $repoRoot 'scripts\pg-incident-recovery.ps1')
. (Join-Path $repoRoot 'scripts\pg-wal-slot-monitor.ps1')

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pg-inc-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

try {
    # 1. Key-value state persistence
    $kvFile = Join-Path $tmpRoot 'state.txt'
    $missingMap = Read-KeyValueFile -Path $kvFile
    Assert-Equal $missingMap.Count 0 "Missing key-value file returns empty hashtable"
    Write-KeyValueFile -Path $kvFile -Map @{ 'svc-b' = 'D:\pg2'; 'svc-a' = 'D:\pg1' }
    $loadedMap = Read-KeyValueFile -Path $kvFile
    Assert-Equal $loadedMap['svc-a'] 'D:\pg1' "Key-value round-trip restores svc-a"
    Assert-Equal $loadedMap['svc-b'] 'D:\pg2' "Key-value round-trip restores svc-b"

    # 2. Stale PID guard (DryRun preserves; real removes)
    $dataDir = Join-Path $tmpRoot 'pgdata'
    New-Item -ItemType Directory -Path (Join-Path $dataDir 'pg_wal') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dataDir 'log') -Force | Out-Null
    $pidFile = Join-Path $dataDir 'postmaster.pid'
    Set-Content -Path $pidFile -Value '999999' -Encoding Ascii

    $dryRes = Test-AndClearStalePid -ServiceName 'pg-test' -DataDirectory $dataDir -DryRunMode
    Assert-True $dryRes "Test-AndClearStalePid succeeds in DryRun"
    Assert-True (Test-Path $pidFile) "DryRun preserves stale postmaster.pid"

    $realRes = Test-AndClearStalePid -ServiceName 'pg-test' -DataDirectory $dataDir
    Assert-True $realRes "Test-AndClearStalePid clears stale PID"
    Assert-True (-not (Test-Path $pidFile)) "Non-DryRun deletes stale postmaster.pid"

    Set-Content -Path $pidFile -Value '' -Encoding Ascii
    [void](Test-AndClearStalePid -ServiceName 'pg-test' -DataDirectory $dataDir)
    Assert-True (-not (Test-Path $pidFile)) "Empty unreadable postmaster.pid is cleared"

    # 3. Crash recovery log detection
    Set-Content -Path (Join-Path $dataDir 'postgresql.conf') -Value "log_directory = 'log'" -Encoding UTF8
    $logPath = Join-Path $dataDir 'log\postgresql-01.log'
    Set-Content -Path $logPath -Value "2026-06-22 10:00:00 LOG: database system was interrupted; last known up at 2026-06-22 09:58:00" -Encoding UTF8
    $inRec = Test-IsInCrashRecovery -DataDirectory $dataDir -Patterns @('database system was interrupted', 'redo starts at')
    Assert-True $inRec "Crash-recovery pattern matches log tail"

    Set-Content -Path $logPath -Value "2026-06-22 10:02:00 LOG: database system is ready to accept connections" -Encoding UTF8
    $notInRec = Test-IsInCrashRecovery -DataDirectory $dataDir -Patterns @('database system was interrupted', 'redo starts at')
    Assert-True (-not $notInRec) "Ready log returns false for in-crash-recovery"

    # 4. pg_controldata WAL-missing verification via mock batch shim
    $mockCtl = Join-Path $tmpRoot 'mock_pg_controldata.cmd'
    $ctlLines = @(
        '@echo off',
        'echo Database cluster state:               in crash recovery',
        'echo Time of latest checkpoint:            Mon Jun 22 09:58:00 2026',
        'echo Latest checkpoint''s REDO WAL file:   00000001000000140000002A'
    )
    Set-Content -Path $mockCtl -Value $ctlLines -Encoding Ascii

    $walMissingResult = Test-WalMissing -DataDirectory $dataDir -PgControlDataPath $mockCtl
    Assert-Equal $walMissingResult.WalFile '00000001000000140000002A' "Extracts REDO WAL filename from pg_controldata"
    Assert-True $walMissingResult.WalMissing "Flags WalMissing=true when REDO WAL segment is absent"

    New-Item -ItemType File -Path (Join-Path $dataDir 'pg_wal\00000001000000140000002A') -Force | Out-Null
    $walPresentResult = Test-WalMissing -DataDirectory $dataDir -PgControlDataPath $mockCtl
    Assert-True (-not $walPresentResult.WalMissing) "Flags WalMissing=false when REDO WAL segment exists"

    # 5. Replication slot name validation (SQL injection defense)
    Assert-True (Test-ValidSlotName 'replica_slot_01') "Accepts valid lowercase slot identifier"
    Assert-True (-not (Test-ValidSlotName "bad'; DROP TABLE t;--")) "Rejects SQL injection in slot identifier"
    Assert-True (-not (Test-ValidSlotName 'UpperCaseSlot')) "Rejects uppercase slot identifier"
    Assert-True (-not (Test-ValidSlotName '')) "Rejects empty slot identifier"
    Assert-True (-not (Test-ValidSlotName ('a' * 64))) "Rejects >63 char PostgreSQL slot identifier"

    $threw = $false
    try {
        [void](Drop-Slot -Instance @{ Name = 'test'; Port = 5432 } -SlotName "x'; SELECT 1;--")
    } catch {
        $threw = $true
    }
    Assert-True $threw "Drop-Slot throws immediately on invalid slot identifier"

    # 6. CSV parser tolerance for empty/NULL numeric fields
    $rowOk = ConvertFrom-SlotCsvLine "replica_a,physical,f,1073741824,536870912"
    Assert-Equal $rowOk.slot_name 'replica_a' "Parses slot_name from CSV"
    Assert-Equal $rowOk.active $false "Parses boolean false flag from psql CSV"
    Assert-Equal $rowOk.bytes_retained 1073741824 "Parses bytes_retained cleanly"

    $rowNull = ConvertFrom-SlotCsvLine "logical_sub,logical,f,,"
    Assert-Equal $rowNull.bytes_retained 0 "Empty/NULL numeric columns fall back cleanly to 0"

    # 7. Persistent inactive-duration state tracker
    $statePath = Join-Path $tmpRoot 'slot_state.json'
    $state = Read-InactiveState -Path $statePath
    $t0 = [datetime]::SpecifyKind([datetime]'2026-06-22T10:00:00', [System.DateTimeKind]::Utc)
    $t1 = $t0.AddMinutes(45)

    $obs = @([PSCustomObject]@{ slot_name = 'orphan_1'; active = $false; bytes_retained = 3GB })
    $d0 = Update-InactiveState -State $state -InstanceName 'PG1' -ObservedSlots $obs -UtcNow $t0
    Assert-Equal ([math]::Round($d0['orphan_1'], 1)) 0.0 "First inactive observation records 0.0 minutes"

    $d1 = Update-InactiveState -State $state -InstanceName 'PG1' -ObservedSlots $obs -UtcNow $t1
    Assert-Equal ([math]::Round($d1['orphan_1'], 1)) 45.0 "Second observation measures 45.0 elapsed inactive minutes"

    Write-InactiveState -Path $statePath -State $state
    $reloaded = Read-InactiveState -Path $statePath
    Assert-True ($reloaded.ContainsKey('PG1:orphan_1')) "State JSON round-trip preserves inactive timestamp"

    # Slot disappears -> state entry purged cleanly
    [void](Update-InactiveState -State $state -InstanceName 'PG1' -ObservedSlots @() -UtcNow $t1.AddMinutes(5))
    Assert-True (-not $state.ContainsKey('PG1:orphan_1')) "Purges inactive timestamp when slot is no longer inactive"

    # 8. Threshold decision matrix + AlertOnly guardrail
    Assert-Equal (Get-SlotAction -RetainedBytes 100MB -MinutesInactive 60 -WarnThresholdBytes 500MB -AutoDropThresholdBytes 2GB -AutoDropInactiveMinutes 30 -AlertOnly $false) 'ok' "Below warn threshold -> ok"
    Assert-Equal (Get-SlotAction -RetainedBytes 800MB -MinutesInactive 60 -WarnThresholdBytes 500MB -AutoDropThresholdBytes 2GB -AutoDropInactiveMinutes 30 -AlertOnly $false) 'warn' "Above warn, below drop -> warn"
    Assert-Equal (Get-SlotAction -RetainedBytes 3GB -MinutesInactive 10 -WarnThresholdBytes 500MB -AutoDropThresholdBytes 2GB -AutoDropInactiveMinutes 30 -AlertOnly $false) 'warn' "Above drop size but below inactive duration gate -> warn only"
    Assert-Equal (Get-SlotAction -RetainedBytes 3GB -MinutesInactive 45 -WarnThresholdBytes 500MB -AutoDropThresholdBytes 2GB -AutoDropInactiveMinutes 30 -AlertOnly $true) 'would_drop' "AlertOnly=true prevents drop"
    Assert-Equal (Get-SlotAction -RetainedBytes 3GB -MinutesInactive 45 -WarnThresholdBytes 500MB -AutoDropThresholdBytes 2GB -AutoDropInactiveMinutes 30 -AlertOnly $false) 'drop' "Exceeds size and inactive duration -> drop"

    # 9. Log message formatting sanity (decimals always rendered)
    $formatted = Format-SlotMessage -InstanceName 'PG1' -SlotName 'orphan_1' -RetainedBytes 2GB -MinutesInactive 45.25 -Action 'would_drop'
    Assert-True ($formatted.Contains('45.2 min inactive') -or $formatted.Contains('45.3 min inactive')) "Format-SlotMessage renders decimal inactive minutes cleanly: $formatted"
}
finally {
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`nSummary: $($script:Passed) passed, $($script:Failed) failed"
if ($script:Failed -gt 0) {
    exit 1
}
exit 0
