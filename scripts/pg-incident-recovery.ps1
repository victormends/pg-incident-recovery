#Requires -Version 5.1

param(
    [string]$ConfigPath = ".\examples\cluster-config.example.json",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$Message) Write-Host "[info] $Message" -ForegroundColor DarkGray }
function Write-Warn { param([string]$Message) Write-Host "[warn] $Message" -ForegroundColor Yellow }
function Write-Ok   { param([string]$Message) Write-Host "[ok]   $Message" -ForegroundColor Green }
function Write-Bad  { param([string]$Message) Write-Host "[fail] $Message" -ForegroundColor Red }

function Read-KeyValueFile {
    param([string]$Path)

    $map = @{}
    if (-not (Test-Path $Path)) { return $map }

    Get-Content $Path | Where-Object { $_ -match '^\S+=.+' } | ForEach-Object {
        $parts = $_ -split '=', 2
        $map[$parts[0].Trim()] = $parts[1].Trim()
    }

    return $map
}

function Write-KeyValueFile {
    param(
        [string]$Path,
        [hashtable]$Map
    )

    $lines = $Map.GetEnumerator() |
        Sort-Object Key |
        ForEach-Object { "$($_.Key)=$($_.Value)" }

    Set-Content -Path $Path -Value $lines
}

function Initialize-File {
    param([string]$Path)

    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Path $Path | Out-Null
    }
}

function Import-Config {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Config file not found: $Path"
    }

    return Get-Content $Path -Raw | ConvertFrom-Json
}

function Get-PostgresToolPath {
    param(
        [string[]]$Candidates,
        [string]$ToolName
    )

    foreach ($candidate in $Candidates) {
        if (-not $candidate) { continue }
        $fullPath = Join-Path $candidate $ToolName
        if (Test-Path $fullPath) {
            return $fullPath
        }
    }

    $fromPath = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    return $null
}

function Get-ServiceMatches {
    param([string[]]$Patterns)

    $foundServices = @()
    foreach ($pattern in $Patterns) {
        $foundServices += Get-Service -Name $pattern -ErrorAction SilentlyContinue
    }

    return $foundServices | Sort-Object Name -Unique
}

function Resolve-DataDirectoryFromService {
    param([string]$ServiceName)

    $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    if (-not $svc -or -not $svc.PathName) { return $null }

    if ($svc.PathName -match '-D\s+"?([^\"]+?)"?(\s+-|$)') {
        return $matches[1].Trim()
    }

    return $null
}

function Get-DriveFreeGb {
    param([string]$DataDirectory)

    $root = [System.IO.Path]::GetPathRoot($DataDirectory)
    if (-not $root) { return $null }

    $driveId = $root.TrimEnd('\\')
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$driveId'" -ErrorAction SilentlyContinue
    if (-not $disk) { return $null }

    return [math]::Round(($disk.FreeSpace / 1GB), 2)
}

function Test-DiskGuard {
    param(
        [string]$DataDirectory,
        [double]$CriticalFreeGb,
        [double]$WarningFreeGb
    )

    $freeGb = Get-DriveFreeGb -DataDirectory $DataDirectory
    if ($null -eq $freeGb) {
        return @{ State = 'unknown'; FreeGb = $null }
    }

    if ($freeGb -lt $CriticalFreeGb) {
        return @{ State = 'critical'; FreeGb = $freeGb }
    }

    if ($freeGb -lt $WarningFreeGb) {
        return @{ State = 'warning'; FreeGb = $freeGb }
    }

    return @{ State = 'ok'; FreeGb = $freeGb }
}

function Test-AndClearStalePid {
    param(
        [string]$ServiceName,
        [string]$DataDirectory,
        [switch]$DryRunMode
    )

    $pidFile = Join-Path $DataDirectory 'postmaster.pid'
    if (-not (Test-Path $pidFile)) {
        return $true
    }

    $pidContent = Get-Content $pidFile -TotalCount 1 -ErrorAction SilentlyContinue
    $storedPid = $pidContent -as [int]

    if (-not $storedPid) {
        Write-Warn "$ServiceName: postmaster.pid is empty or unreadable. Removing stale file."
        if (-not $DryRunMode) {
            Remove-Item $pidFile -Force
        }
        return $true
    }

    $processRunning = Get-Process -Id $storedPid -ErrorAction SilentlyContinue
    if ($processRunning) {
        Write-Warn "$ServiceName: PID $storedPid is still running. Attempting to stop the stale postgres process."
        if ($DryRunMode) {
            return $true
        }

        try {
            Stop-Process -Id $storedPid -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
        }
        catch {
            Write-Bad "$ServiceName: failed to stop process $storedPid. Manual intervention required."
            return $false
        }
    }

    if (-not $DryRunMode) {
        Remove-Item $pidFile -Force
    }

    Write-Info "$ServiceName: stale postmaster.pid cleared."
    return $true
}

function Get-PostgresProcessForDataDirectory {
    param([string]$DataDirectory)

    $normalizedDir = $DataDirectory.TrimEnd('\\').ToLower()
    $candidates = Get-CimInstance Win32_Process -Filter "Name='postgres.exe'" -ErrorAction SilentlyContinue
    foreach ($proc in $candidates) {
        if ($proc.CommandLine -and $proc.CommandLine.ToLower() -match [regex]::Escape($normalizedDir)) {
            return $proc
        }
    }

    return $null
}

function Get-LatestLogFile {
    param([string]$DataDirectory)

    $logDir = $null
    $configPath = Join-Path $DataDirectory 'postgresql.conf'

    if (Test-Path $configPath) {
        $configLines = Get-Content $configPath -ErrorAction SilentlyContinue
        foreach ($line in $configLines) {
            if ($line -match '^\s*log_directory\s*=\s*''?([^''#]+)''?') {
                $candidate = $matches[1].Trim()
                if ([System.IO.Path]::IsPathRooted($candidate)) {
                    $logDir = $candidate
                }
                else {
                    $logDir = Join-Path $DataDirectory $candidate
                }
                break
            }
        }
    }

    if (-not $logDir) {
        foreach ($fallback in @('log', 'pg_log')) {
            $candidateDir = Join-Path $DataDirectory $fallback
            if (Test-Path $candidateDir) {
                $logDir = $candidateDir
                break
            }
        }
    }

    if (-not $logDir -or -not (Test-Path $logDir)) { return $null }

    return Get-ChildItem $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Test-IsInCrashRecovery {
    param(
        [string]$DataDirectory,
        [string[]]$Patterns
    )

    $latestLog = Get-LatestLogFile -DataDirectory $DataDirectory
    if (-not $latestLog) { return $false }

    $lines = Get-Content $latestLog.FullName -Tail 50 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        foreach ($pattern in $Patterns) {
            if ($line -match $pattern) {
                return $true
            }
        }
    }

    return $false
}

function Test-WalMissing {
    param(
        [string]$DataDirectory,
        [string]$PgControlDataPath
    )

    if (-not $PgControlDataPath) { return $null }

    try {
        $pgControlData = & $PgControlDataPath $DataDirectory 2>$null
        if (-not $pgControlData) { return $null }

        $walFile = $null
        $lastCheckpoint = $null
        $dbState = $null

        foreach ($line in $pgControlData) {
            if (-not $walFile -and $line -match "(?:Latest checkpoint's )?REDO WAL file:\s+(\S+)") {
                $walFile = $matches[1].Trim()
                continue
            }

            if (-not $lastCheckpoint -and $line -match "Time of latest checkpoint:\s+(.+)") {
                $lastCheckpoint = $matches[1].Trim()
                continue
            }

            if (-not $dbState -and $line -match "(?:Database )?cluster state:\s+(.+)") {
                $dbState = $matches[1].Trim()
                continue
            }
        }

        if (-not $walFile) {
            Write-Warn "Could not extract REDO WAL file from pg_controldata output for $DataDirectory. WAL-missing detection skipped."
            return $null
        }

        $walPath = Join-Path (Join-Path $DataDirectory 'pg_wal') $walFile
        return @{
            WalFile = $walFile
            WalMissing = -not (Test-Path $walPath)
            LastCheckpoint = $lastCheckpoint
            DbState = $dbState
        }
    }
    catch {
        return $null
    }
}

function Write-LogTail {
    param([string]$DataDirectory)

    $latestLog = Get-LatestLogFile -DataDirectory $DataDirectory
    if (-not $latestLog) { return }

    Write-Info "Last log lines from $($latestLog.Name):"
    Get-Content $latestLog.FullName -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "       $_" -ForegroundColor DarkGray
    }
}

function Update-ClusterMapEntry {
    param(
        [string]$ServiceName,
        [string]$DataDirectory,
        [string]$PsqlPath,
        [string]$ClusterMapFile,
        [string]$ProbeUser
    )

    if (-not $PsqlPath) { return }

    try {
        $port = $null
        $configPath = Join-Path $DataDirectory 'postgresql.conf'
        if (-not (Test-Path $configPath)) { return }

        $configLines = Get-Content $configPath -ErrorAction SilentlyContinue
        foreach ($line in $configLines) {
            if ($line -match '^\s*port\s*=\s*(\d+)') {
                $port = $matches[1].Trim()
                break
            }
        }

        if (-not $port) { return }

        $result = & $PsqlPath -U $ProbeUser -p $port -t -c "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') LIMIT 1;" 2>$null
        $dbNameLine = $result | Where-Object { $_ -match '\S' } | Select-Object -First 1
        if (-not $dbNameLine) { return }
        $dbName = $dbNameLine.Trim()
        if (-not $dbName) { return }

        $existing = Read-KeyValueFile -Path $ClusterMapFile
        $existing[$ServiceName] = $dbName
        Write-KeyValueFile -Path $ClusterMapFile -Map $existing
    }
    catch {
        Write-Warn "Failed to update cluster map for $ServiceName: $($_.Exception.Message)"
    }
}

function Invoke-StartPass {
    param(
        [string[]]$ServiceList,
        [hashtable]$DataDirMap,
        [pscustomobject]$Config,
        [string]$PsqlPath,
        [string]$PgControlDataPath,
        [string]$ClusterMapFile,
        [string]$ProbeUser,
        [switch]$DryRunMode
    )

    $readyToStart = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $walCorrupted = New-Object System.Collections.Generic.List[string]

    foreach ($name in $ServiceList) {
        Write-Host "`n[$name] Preparing..." -ForegroundColor Cyan

        if (-not $DataDirMap.ContainsKey($name)) {
            Write-Bad "$name: data directory could not be resolved."
            $skipped.Add($name)
            continue
        }

        $dataDir = $DataDirMap[$name]
        Write-Info "$name: using resolved data directory $dataDir"
        $diskState = Test-DiskGuard -DataDirectory $dataDir -CriticalFreeGb $Config.disk.critical_free_gb -WarningFreeGb $Config.disk.warning_free_gb
        if ($diskState.State -eq 'critical') {
            Write-Bad "$name: drive has only $($diskState.FreeGb) GB free. Aborting run to avoid corruption risk."
            throw "Critical free-space threshold reached."
        }
        elseif ($diskState.State -eq 'warning') {
            Write-Warn "$name: low free space detected ($($diskState.FreeGb) GB)."
        }

        $walCheck = Test-WalMissing -DataDirectory $dataDir -PgControlDataPath $PgControlDataPath
        if ($walCheck -and $walCheck.WalMissing) {
            Write-Bad "$name: required WAL file is missing ($($walCheck.WalFile)). Restore from backup is required."
            $walCorrupted.Add($name)
            continue
        }

        $pidClean = Test-AndClearStalePid -ServiceName $name -DataDirectory $dataDir -DryRunMode:$DryRunMode
        if (-not $pidClean) {
            $skipped.Add($name)
            continue
        }

        $readyToStart.Add($name)
        Write-Info "$name: ready to start."
    }

    $passResolved = New-Object System.Collections.Generic.List[string]
    $passFailed = New-Object System.Collections.Generic.List[string]
    $recoveryQueue = @{}

    if ($readyToStart.Count -eq 0) {
        return @{ Resolved = $passResolved; Failed = $passFailed; Skipped = $skipped; WalCorrupted = $walCorrupted }
    }

    Write-Host "`n--- Starting $($readyToStart.Count) service(s) ---" -ForegroundColor Cyan

    Import-Module ThreadJob -ErrorAction SilentlyContinue
    $useThreadJob = [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
    $throttle = [Math]::Min([int]$Config.recovery.max_parallel_starts, [Math]::Max($readyToStart.Count, 1))

    $scriptBlock = {
        param($serviceName, $dryRun)
        if ($dryRun) { return 'ok' }
        try {
            Start-Service -Name $serviceName -ErrorAction Stop -WarningAction SilentlyContinue
            return 'ok'
        }
        catch {
            return "fail:$_"
        }
    }

    $jobs = @{}
    foreach ($name in $readyToStart) {
        if ($useThreadJob) {
            $jobs[$name] = Start-ThreadJob -ScriptBlock $scriptBlock -ArgumentList $name, [bool]$DryRunMode -ThrottleLimit $throttle
        }
        else {
            $jobs[$name] = Start-Job -ScriptBlock $scriptBlock -ArgumentList $name, [bool]$DryRunMode
        }
    }

    $jobs.Values | Wait-Job | Out-Null

    foreach ($name in $jobs.Keys) {
        $result = Receive-Job -Job $jobs[$name]
        Remove-Job -Job $jobs[$name] -Force
        $dataDir = $DataDirMap[$name]

        if ($result -eq 'ok') {
            Write-Ok "$name: started successfully."
            $passResolved.Add($name)
            if (-not $DryRunMode) {
                Update-ClusterMapEntry -ServiceName $name -DataDirectory $dataDir -PsqlPath $PsqlPath -ClusterMapFile $ClusterMapFile -ProbeUser $ProbeUser
            }
            continue
        }

        $proc = Get-PostgresProcessForDataDirectory -DataDirectory $dataDir
        $inCrashRecovery = Test-IsInCrashRecovery -DataDirectory $dataDir -Patterns $Config.log_patterns.recovery_in_progress

        if ($proc -and $inCrashRecovery) {
            Write-Warn "$name: postgres process is alive and logs indicate crash recovery. Queuing for wait path."
            $recoveryQueue[$name] = $dataDir
            continue
        }

        $walCheck = Test-WalMissing -DataDirectory $dataDir -PgControlDataPath $PgControlDataPath
        if ($walCheck -and $walCheck.WalMissing) {
            Write-Bad "$name: required WAL file is missing after failed start ($($walCheck.WalFile))."
            $walCorrupted.Add($name)
            continue
        }

        $errMsg = ($result -replace '^fail:', '').Trim()
        Write-Bad "$name: failed to start."
        if ($errMsg) {
            Write-Info "$name: service error: $errMsg"
        }
        Write-LogTail -DataDirectory $dataDir
        $passFailed.Add($name)
    }

    if ($recoveryQueue.Count -gt 0) {
        Write-Host "`n--- Waiting for $($recoveryQueue.Count) cluster(s) in crash recovery ---" -ForegroundColor Yellow

        Import-Module ThreadJob -ErrorAction SilentlyContinue
        $useRecoveryThreadJob = [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
        $recoveryScriptBlock = {
            param($serviceName, $serviceDataDir, $timeoutSeconds, $pollSeconds, $readyPatterns, $dryRun)

            $waited = 0
            $normalizedDir = $serviceDataDir.TrimEnd('\\').ToLower()

            while ($waited -lt $timeoutSeconds) {
                Start-Sleep -Seconds $pollSeconds
                $waited += $pollSeconds

                $status = (Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
                if ($status -eq 'Running') {
                    return "ok:$waited"
                }

                $alive = Get-CimInstance Win32_Process -Filter "Name='postgres.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -and $_.CommandLine.ToLower() -match [regex]::Escape($normalizedDir) }
                if (-not $alive) {
                    return 'died'
                }

                $logDir = Join-Path $serviceDataDir 'log'
                $latestLog = Get-ChildItem $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1

                if ($latestLog) {
                    $lines = Get-Content $latestLog.FullName -Tail 30 -ErrorAction SilentlyContinue
                    $completed = $false
                    foreach ($line in $lines) {
                        foreach ($pattern in $readyPatterns) {
                            if ($line -match $pattern) {
                                $completed = $true
                                break
                            }
                        }
                        if ($completed) { break }
                    }

                    if ($completed) {
                        if ($dryRun) {
                            return "ok-scm-restart:$waited"
                        }

                        $proc = Get-CimInstance Win32_Process -Filter "Name='postgres.exe'" -ErrorAction SilentlyContinue |
                            Where-Object { $_.CommandLine -and $_.CommandLine.ToLower() -match [regex]::Escape($normalizedDir) }
                        if ($proc) {
                            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
                            Start-Sleep -Seconds 3
                        }

                        $pidFile = Join-Path $serviceDataDir 'postmaster.pid'
                        if (Test-Path $pidFile) {
                            Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
                        }

                        Start-Service -Name $serviceName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 5

                        $restartStatus = (Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
                        if ($restartStatus -eq 'Running') {
                            return "ok-scm-restart:$waited"
                        }

                        return 'scm-restart-failed'
                    }
                }
            }

            return 'timeout'
        }

        $recoveryJobs = @{}
        foreach ($name in $recoveryQueue.Keys) {
            $dataDir = $recoveryQueue[$name]
            if ($useRecoveryThreadJob) {
                $recoveryJobs[$name] = Start-ThreadJob -ScriptBlock $recoveryScriptBlock -ArgumentList $name, $dataDir, ([int]$Config.recovery.recovery_timeout_seconds), ([int]$Config.recovery.recovery_poll_seconds), $Config.log_patterns.ready, [bool]$DryRunMode
            }
            else {
                $recoveryJobs[$name] = Start-Job -ScriptBlock $recoveryScriptBlock -ArgumentList $name, $dataDir, ([int]$Config.recovery.recovery_timeout_seconds), ([int]$Config.recovery.recovery_poll_seconds), $Config.log_patterns.ready, [bool]$DryRunMode
            }
        }

        $recoveryJobs.Values | Wait-Job | Out-Null

        foreach ($name in $recoveryJobs.Keys) {
            $result = Receive-Job -Job $recoveryJobs[$name]
            Remove-Job -Job $recoveryJobs[$name] -Force
            $dataDir = $recoveryQueue[$name]

            if ($result -like 'ok:*') {
                $secs = $result -replace '^ok:', ''
                Write-Ok "$name: recovery completed after $secs seconds."
                $passResolved.Add($name)
                if (-not $DryRunMode) {
                    Update-ClusterMapEntry -ServiceName $name -DataDirectory $dataDir -PsqlPath $PsqlPath -ClusterMapFile $ClusterMapFile -ProbeUser $ProbeUser
                }
            }
            elseif ($result -like 'ok-scm-restart:*') {
                $secs = $result -replace '^ok-scm-restart:', ''
                Write-Ok "$name: recovery completed and service restarted cleanly under SCM after $secs seconds."
                $passResolved.Add($name)
                if (-not $DryRunMode) {
                    Update-ClusterMapEntry -ServiceName $name -DataDirectory $dataDir -PsqlPath $PsqlPath -ClusterMapFile $ClusterMapFile -ProbeUser $ProbeUser
                }
            }
            elseif ($result -eq 'died') {
                Write-Bad "$name: postgres process died during crash recovery."
                Write-LogTail -DataDirectory $dataDir
                $passFailed.Add($name)
            }
            elseif ($result -eq 'scm-restart-failed') {
                Write-Bad "$name: recovery completed but clean SCM restart failed."
                Write-LogTail -DataDirectory $dataDir
                $passFailed.Add($name)
            }
            else {
                Write-Bad "$name: recovery timed out after $($Config.recovery.recovery_timeout_seconds) seconds."
                Write-LogTail -DataDirectory $dataDir
                $passFailed.Add($name)
            }
        }
    }

    return @{ Resolved = $passResolved; Failed = $passFailed; Skipped = $skipped; WalCorrupted = $walCorrupted }
}

$config = Import-Config -Path $ConfigPath

$stateDir = $config.state_dir
$queueFile = Join-Path $stateDir 'failed-clusters.txt'
$clusterMapFile = Join-Path $stateDir 'cluster-map.txt'
$logFile = Join-Path $stateDir ('run-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

Initialize-File -Path $queueFile
Initialize-File -Path $clusterMapFile
Initialize-File -Path $logFile

$probeUser = if ($config.cluster_map_probe_user) { [string]$config.cluster_map_probe_user } else { 'postgres' }

if (-not $DryRun) {
    try {
        Start-Transcript -Path $logFile -Append | Out-Null
        Write-Info "Transcript started at $logFile"
    }
    catch {
        Write-Warn "Could not start transcript logging: $($_.Exception.Message)"
    }
}

$psqlPath = Get-PostgresToolPath -Candidates $config.pg_bin_candidates -ToolName 'psql.exe'
$pgControlDataPath = Get-PostgresToolPath -Candidates $config.pg_bin_candidates -ToolName 'pg_controldata.exe'

if (-not $pgControlDataPath) {
    Write-Warn 'pg_controldata.exe not found. WAL-missing detection will be limited.'
}

Write-Info 'Waiting 10 seconds for the Service Control Manager to settle...'
Start-Sleep -Seconds 10

$services = Get-ServiceMatches -Patterns $config.service_name_patterns | Where-Object { $_.Status -eq 'Stopped' }
if (-not $services) {
    Write-Ok 'No stopped PostgreSQL services matched the configured patterns.'
    exit 0
}

$queueCache = Read-KeyValueFile -Path $queueFile
foreach ($svc in $services) {
    if (-not $queueCache.ContainsKey($svc.Name)) {
        $dataDir = Resolve-DataDirectoryFromService -ServiceName $svc.Name
        if ($dataDir) {
            $queueCache[$svc.Name] = $dataDir
        }
    }
}

$firstPass = Invoke-StartPass -ServiceList $services.Name -DataDirMap $queueCache -Config $config -PsqlPath $psqlPath -PgControlDataPath $pgControlDataPath -ClusterMapFile $clusterMapFile -ProbeUser $probeUser -DryRunMode:$DryRun

$totalResolved = New-Object System.Collections.Generic.List[string]
$totalFailed = New-Object System.Collections.Generic.List[string]
$totalSkipped = New-Object System.Collections.Generic.List[string]
$totalWalCorrupt = New-Object System.Collections.Generic.List[string]

foreach ($n in $firstPass.Resolved)     { $totalResolved.Add($n) }
foreach ($n in $firstPass.Failed)       { $totalFailed.Add($n) }
foreach ($n in $firstPass.Skipped)      { $totalSkipped.Add($n) }
foreach ($n in $firstPass.WalCorrupted) { $totalWalCorrupt.Add($n) }

$retryCount = 0
while ($totalFailed.Count -gt 0 -and $retryCount -lt [int]$config.recovery.max_retries) {
    $retryCount++
    Write-Warn "Retry $retryCount of $($config.recovery.max_retries): $($totalFailed.Count) service(s) still failing."
    Start-Sleep -Seconds ([int]$config.recovery.retry_delay_seconds)

    $retryList = $totalFailed.ToArray()
    $totalFailed.Clear()

    $retryPass = Invoke-StartPass -ServiceList $retryList -DataDirMap $queueCache -Config $config -PsqlPath $psqlPath -PgControlDataPath $pgControlDataPath -ClusterMapFile $clusterMapFile -ProbeUser $probeUser -DryRunMode:$DryRun

    foreach ($n in $retryPass.Resolved)     { $totalResolved.Add($n) }
    foreach ($n in $retryPass.Failed)       { $totalFailed.Add($n) }
    foreach ($n in $retryPass.Skipped)      { $totalSkipped.Add($n) }
    foreach ($n in $retryPass.WalCorrupted) { $totalWalCorrupt.Add($n) }
}

$resolvedArray = $totalResolved.ToArray()
$finalQueue = @{}
foreach ($entry in $queueCache.GetEnumerator()) {
    if (-not ($resolvedArray -icontains $entry.Key)) {
        $finalQueue[$entry.Key] = $entry.Value
    }
}

if (-not $DryRun) {
    Write-KeyValueFile -Path $queueFile -Map $finalQueue
}

$clusterMap = Read-KeyValueFile -Path $clusterMapFile

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "Recovered automatically : $($totalResolved.Count)" -ForegroundColor Green
foreach ($n in $totalResolved) {
    $db = if ($clusterMap.ContainsKey($n)) { $clusterMap[$n] } else { '?' }
    Write-Host "  + $n ($db)" -ForegroundColor Green
}

Write-Host "Still failing          : $($totalFailed.Count)" -ForegroundColor $(if ($totalFailed.Count -gt 0) { 'Red' } else { 'Green' })
foreach ($n in $totalFailed) {
    $db = if ($clusterMap.ContainsKey($n)) { $clusterMap[$n] } else { '?' }
    Write-Host "  - $n ($db)" -ForegroundColor Red
}

Write-Host "WAL missing / fatal    : $($totalWalCorrupt.Count)" -ForegroundColor $(if ($totalWalCorrupt.Count -gt 0) { 'Red' } else { 'Green' })
foreach ($n in $totalWalCorrupt) {
    $db = if ($clusterMap.ContainsKey($n)) { $clusterMap[$n] } else { '?' }
    Write-Host "  ! $n ($db) - restore from backup required" -ForegroundColor Red
}

Write-Host "Skipped                : $($totalSkipped.Count)" -ForegroundColor $(if ($totalSkipped.Count -gt 0) { 'Yellow' } else { 'Green' })
foreach ($n in $totalSkipped) {
    Write-Host "  ~ $n" -ForegroundColor Yellow
}

Write-Host "Queue file             : $queueFile" -ForegroundColor DarkGray
Write-Host "Cluster map            : $clusterMapFile" -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Cyan
