#requires -version 3.0
param(
    [switch]$Resume,
    [int]$ExternalServicingWaitMinutes = 90,
    [int]$HeartbeatSeconds = 5,
    [int]$CommandTimeoutMinutes = 240,
    [switch]$NoCacheReset
)

$ErrorActionPreference = 'Stop'

$Script:ExternalServicingWaitMinutes = $ExternalServicingWaitMinutes
$Script:HeartbeatSeconds = $HeartbeatSeconds
$Script:CommandTimeoutMinutes = $CommandTimeoutMinutes
$Script:RepairRoot = Join-Path $env:ProgramData 'Codex\WindowsServicingRepair'
$Script:RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Script:RunRoot = Join-Path $Script:RepairRoot $Script:RunStamp
$Script:LogPath = Join-Path $Script:RunRoot 'repair.log'
$Script:TranscriptPath = Join-Path $Script:RunRoot 'transcript.log'
$Script:TaskName = 'Codex-WindowsServicingRepair-Resume'

function New-RepairDirectory {
    if (-not (Test-Path -LiteralPath $Script:RunRoot)) {
        New-Item -Path $Script:RunRoot -ItemType Directory -Force | Out-Null
    }
}

function Write-RepairStatus {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','PASS')][string]$Level = 'INFO'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $Script:LogPath -Value $line -Encoding UTF8
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SystemTool {
    param([Parameter(Mandatory=$true)][string]$Name)
    $path = Join-Path $env:windir ("System32\{0}" -f $Name)
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required Windows tool not found: $path"
    }
    return $path
}

function Invoke-LoggedNative {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string]$Arguments,
        [Parameter(Mandatory=$true)][string]$Name,
        [int]$TimeoutMinutes = $Script:CommandTimeoutMinutes
    )

    $safeName = ($Name -replace '[^A-Za-z0-9_.-]', '_')
    $stdoutPath = Join-Path $Script:RunRoot ("{0}.stdout.log" -f $safeName)
    $stderrPath = Join-Path $Script:RunRoot ("{0}.stderr.log" -f $safeName)
    if (Test-Path -LiteralPath $stdoutPath) { Remove-Item -LiteralPath $stdoutPath -Force }
    if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force }

    Write-RepairStatus "START $Name :: $FilePath $Arguments"

    $cmdLine = '/d /c ""{0}" {1} 1>>"{2}" 2>>"{3}"""' -f $FilePath, $Arguments, $stdoutPath, $stderrPath
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine -WindowStyle Hidden -PassThru
    $start = Get-Date
    $lastOutLength = 0L
    $lastErrLength = 0L

    while (-not $process.HasExited) {
        Start-Sleep -Seconds $Script:HeartbeatSeconds
        $process.Refresh()
        $elapsed = New-TimeSpan -Start $start -End (Get-Date)
        Write-RepairStatus ("RUNNING {0}: elapsed={1:c} pid={2}" -f $Name, $elapsed, $process.Id)

        foreach ($pair in @(@($stdoutPath, 'OUT'), @($stderrPath, 'ERR'))) {
            $path = $pair[0]
            $kind = $pair[1]
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path -Force
                $oldLength = if ($kind -eq 'OUT') { $lastOutLength } else { $lastErrLength }
                if ($item.Length -gt $oldLength) {
                    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    try {
                        [void]$stream.Seek($oldLength, [System.IO.SeekOrigin]::Begin)
                        $reader = New-Object System.IO.StreamReader($stream)
                        $text = $reader.ReadToEnd()
                    } finally {
                        $stream.Close()
                    }
                    if ($kind -eq 'OUT') { $lastOutLength = $item.Length } else { $lastErrLength = $item.Length }
                    foreach ($line in ($text -split "`r?`n")) {
                        $clean = $line.Trim()
                        if ($clean.Length -gt 0) {
                            Write-RepairStatus ("{0} {1}: {2}" -f $Name, $kind, $clean)
                        }
                    }
                }
            }
        }

        if ($elapsed.TotalMinutes -ge $TimeoutMinutes) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
            throw "$Name exceeded timeout of $TimeoutMinutes minute(s). Logs: $stdoutPath $stderrPath"
        }
    }

    $process.Refresh()
    foreach ($path in @($stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $path) {
            foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
                if ($line.Trim().Length -gt 0) {
                    Add-Content -LiteralPath $Script:LogPath -Value ("[{0}] [CAPTURE] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $line) -Encoding UTF8
                }
            }
        }
    }

    Write-RepairStatus ("END {0}: exit={1}" -f $Name, $process.ExitCode)
    return [pscustomobject]@{
        Name = $Name
        ExitCode = $process.ExitCode
        StdOutPath = $stdoutPath
        StdErrPath = $stderrPath
    }
}

function Get-OutputText {
    param([Parameter(Mandatory=$true)]$Result)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($Result.StdOutPath, $Result.StdErrPath)) {
        if (Test-Path -LiteralPath $path) {
            $parts.Add((Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue))
        }
    }
    return ($parts -join "`n")
}

function Test-PendingServicing {
    $checks = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($path in $checks) {
        if (Test-Path -LiteralPath $path) {
            return $true
        }
    }
    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if (Test-Path -LiteralPath $sessionManager) {
        $props = Get-ItemProperty -LiteralPath $sessionManager -ErrorAction SilentlyContinue
        if ($props.PendingFileRenameOperations) {
            $repairCritical = $props.PendingFileRenameOperations | Where-Object {
                $_ -match '\\Windows\\(WinSxS|servicing|System32\\catroot|System32\\config|SoftwareDistribution)'
            }
            if ($repairCritical) {
                return $true
            }
        }
    }
    return $false
}

function Wait-ExternalServicing {
    $deadline = (Get-Date).AddMinutes($Script:ExternalServicingWaitMinutes)
    $lastMovement = Get-Date
    $lastCpu = -1.0
    $dismLog = Join-Path $env:windir 'Logs\DISM\dism.log'
    $cbsLog = Join-Path $env:windir 'Logs\CBS\CBS.log'
    $lastDismWrite = if (Test-Path -LiteralPath $dismLog) { (Get-Item -LiteralPath $dismLog).LastWriteTime } else { [DateTime]::MinValue }
    $lastCbsWrite = if (Test-Path -LiteralPath $cbsLog) { (Get-Item -LiteralPath $cbsLog).LastWriteTime } else { [DateTime]::MinValue }

    while ($true) {
        $active = Get-Process -Name Dism,DismHost,TiWorker -ErrorAction SilentlyContinue |
            Select-Object ProcessName,Id,StartTime,CPU,Path
        if (-not $active) {
            Write-RepairStatus 'No active external DISM/TiWorker process remains.'
            return
        }

        $currentCpu = ($active | Measure-Object -Property CPU -Sum).Sum
        $currentDismWrite = if (Test-Path -LiteralPath $dismLog) { (Get-Item -LiteralPath $dismLog).LastWriteTime } else { [DateTime]::MinValue }
        $currentCbsWrite = if (Test-Path -LiteralPath $cbsLog) { (Get-Item -LiteralPath $cbsLog).LastWriteTime } else { [DateTime]::MinValue }
        if (($lastCpu -lt 0) -or ([Math]::Abs($currentCpu - $lastCpu) -gt 0.25) -or ($currentDismWrite -gt $lastDismWrite) -or ($currentCbsWrite -gt $lastCbsWrite)) {
            $lastMovement = Get-Date
            $lastCpu = $currentCpu
            $lastDismWrite = $currentDismWrite
            $lastCbsWrite = $currentCbsWrite
        }

        foreach ($proc in $active) {
            Write-RepairStatus ("Waiting for existing servicing process: name={0} pid={1} cpu={2} started={3}" -f $proc.ProcessName, $proc.Id, $proc.CPU, $proc.StartTime)
        }

        $onlyTiWorker = @($active | Where-Object { $_.ProcessName -ne 'TiWorker' }).Count -eq 0
        $idleMinutes = ((Get-Date) - $lastMovement).TotalMinutes
        if ($onlyTiWorker -and $idleMinutes -ge 10) {
            foreach ($ti in @($active | Where-Object { $_.ProcessName -eq 'TiWorker' })) {
                Write-RepairStatus ("Recycling stale TiWorker pid={0}; no CPU/log movement for {1:n1} minute(s)." -f $ti.Id, $idleMinutes) 'WARN'
                Stop-Process -Id $ti.Id -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 5
            continue
        }

        if ((Get-Date) -ge $deadline) {
            throw "Existing DISM/TiWorker activity did not finish within $Script:ExternalServicingWaitMinutes minute(s). Run log: $Script:LogPath"
        }
        Start-Sleep -Seconds $Script:HeartbeatSeconds
    }
}

function Ensure-ServiceUsable {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$StartupType = 'Manual',
        [switch]$Start
    )

    $svc = Get-Service -Name $Name -ErrorAction Stop
    $wmi = Get-WmiObject -Class Win32_Service -Filter ("Name='{0}'" -f $Name)
    if ($wmi.StartMode -eq 'Disabled') {
        Write-RepairStatus "Service $Name is disabled; setting startup to $StartupType."
        Set-Service -Name $Name -StartupType $StartupType
    }
    if ($Start -and $svc.Status -ne 'Running') {
        Write-RepairStatus "Starting service $Name."
        Start-Service -Name $Name -ErrorAction Stop
    } else {
        Write-RepairStatus ("Service {0}: status={1} startMode={2}" -f $Name, $svc.Status, $wmi.StartMode)
    }
}

function Stop-ConflictingRepairLoops {
    $currentPid = $PID
    $conflicts = Get-WmiObject -Class Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $currentPid -and
            (
                ($_.CommandLine -match 'Unstuck-Command\.ps1' -and $_.CommandLine -match 'RerunDism') -or
                ($_.CommandLine -match 'Test-UnstuckCommand\.ps1')
            )
        }

    foreach ($conflict in $conflicts) {
        Write-RepairStatus ("Stopping conflicting repair loop pid={0} command={1}" -f $conflict.ProcessId, $conflict.CommandLine) 'WARN'
        try {
            Stop-Process -Id $conflict.ProcessId -Force -ErrorAction Stop
        } catch {
            Write-RepairStatus "Could not stop conflicting repair loop pid=$($conflict.ProcessId): $($_.Exception.Message)" 'WARN'
        }
    }
}

function Reset-WindowsUpdateCaches {
    if ($NoCacheReset) {
        Write-RepairStatus 'Skipping Windows Update cache reset because -NoCacheReset was supplied.'
        return
    }

    Write-RepairStatus 'Resetting Windows Update download/catalog caches after repair failure evidence.'
    foreach ($svc in 'wuauserv','bits','cryptsvc') {
        try {
            $service = Get-Service -Name $svc -ErrorAction Stop
            if ($service.Status -ne 'Stopped') {
                Write-RepairStatus "Stopping $svc."
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
            }
        } catch {
            Write-RepairStatus "Could not stop $svc cleanly: $($_.Exception.Message)" 'WARN'
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $targets = @(
        (Join-Path $env:windir 'SoftwareDistribution'),
        (Join-Path $env:windir 'System32\catroot2')
    )
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target) {
            $dest = "{0}.codexrepair.{1}.bak" -f $target, $stamp
            try {
                Rename-Item -LiteralPath $target -NewName (Split-Path -Leaf $dest) -ErrorAction Stop
                Write-RepairStatus "Renamed $target to $dest"
            } catch {
                Write-RepairStatus "Could not rename ${target}: $($_.Exception.Message)" 'WARN'
            }
        }
    }

    foreach ($svc in 'cryptsvc','bits','wuauserv') {
        try {
            Write-RepairStatus "Starting $svc."
            Start-Service -Name $svc -ErrorAction SilentlyContinue
        } catch {
            Write-RepairStatus "Could not start $svc cleanly: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Install-ResumeTask {
    $ps5 = Get-SystemTool 'WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = $PSCommandPath
    $tr = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Resume' -f $ps5, $scriptPath
    $schtasks = Get-SystemTool 'schtasks.exe'
    $args = '/Create /TN "{0}" /TR "{1}" /SC ONLOGON /RL HIGHEST /F' -f $Script:TaskName, $tr
    $result = Invoke-LoggedNative -FilePath $schtasks -Arguments $args -Name 'install_resume_task' -TimeoutMinutes 2
    if ($result.ExitCode -eq 0) {
        Write-RepairStatus "Installed resume task $Script:TaskName for next logon after reboot." 'PASS'
    } else {
        Write-RepairStatus "Resume task install returned exit $($result.ExitCode)." 'WARN'
    }
}

function Remove-ResumeTask {
    $schtasks = Get-SystemTool 'schtasks.exe'
    $args = '/Delete /TN "{0}" /F' -f $Script:TaskName
    try {
        [void](Invoke-LoggedNative -FilePath $schtasks -Arguments $args -Name 'remove_resume_task' -TimeoutMinutes 2)
    } catch {
        Write-RepairStatus "Resume task removal skipped or failed: $($_.Exception.Message)" 'WARN'
    }
}

function Assert-NoPendingServicingOrInstallResume {
    if (Test-PendingServicing) {
        Write-RepairStatus 'Windows reports pending CBS/session/file-rename work. Installing resume task and stopping before unsafe DISM/SFC retries.' 'WARN'
        Install-ResumeTask
        Write-RepairStatus 'REBOOT_REQUIRED: reboot Windows, log in, and this script will resume automatically.' 'WARN'
        exit 3010
    }
}

function Invoke-RepairSequence {
    $dism = Get-SystemTool 'dism.exe'
    $sfc = Get-SystemTool 'sfc.exe'
    $chkdsk = Get-SystemTool 'chkdsk.exe'

    Ensure-ServiceUsable -Name 'RpcSs' -StartupType 'Automatic'
    Ensure-ServiceUsable -Name 'DcomLaunch' -StartupType 'Automatic'
    Ensure-ServiceUsable -Name 'RpcEptMapper' -StartupType 'Automatic'
    Ensure-ServiceUsable -Name 'TrustedInstaller' -StartupType 'Manual' -Start
    Ensure-ServiceUsable -Name 'wuauserv' -StartupType 'Manual'
    Ensure-ServiceUsable -Name 'bits' -StartupType 'Manual'
    Ensure-ServiceUsable -Name 'cryptsvc' -StartupType 'Automatic' -Start

    Stop-ConflictingRepairLoops
    Wait-ExternalServicing
    Assert-NoPendingServicingOrInstallResume

    $scan = Invoke-LoggedNative -FilePath $dism -Arguments '/Online /Cleanup-Image /ScanHealth' -Name 'dism_scanhealth'
    if ($scan.ExitCode -ne 0) {
        Write-RepairStatus "DISM ScanHealth returned $($scan.ExitCode); continuing to RestoreHealth." 'WARN'
    }

    $restore = Invoke-LoggedNative -FilePath $dism -Arguments '/Online /Cleanup-Image /RestoreHealth' -Name 'dism_restorehealth'
    $restoreText = Get-OutputText -Result $restore
    if ($restore.ExitCode -ne 0 -or $restoreText -match '1726|remote procedure call failed|0x800706BE|0x800706BA') {
        Write-RepairStatus 'RestoreHealth failed with servicing/RPC evidence; applying cache reset and retry sequence.' 'WARN'
        Reset-WindowsUpdateCaches
        Wait-ExternalServicing
        Assert-NoPendingServicingOrInstallResume
        [void](Invoke-LoggedNative -FilePath $dism -Arguments '/Online /Cleanup-Image /StartComponentCleanup' -Name 'dism_startcomponentcleanup' -TimeoutMinutes 180)
        Wait-ExternalServicing
        Assert-NoPendingServicingOrInstallResume
        $restore = Invoke-LoggedNative -FilePath $dism -Arguments '/Online /Cleanup-Image /RestoreHealth' -Name 'dism_restorehealth_retry'
    }
    if ($restore.ExitCode -ne 0) {
        throw "DISM RestoreHealth failed after retry. Exit=$($restore.ExitCode). Run log: $Script:LogPath"
    }

    Wait-ExternalServicing
    Assert-NoPendingServicingOrInstallResume

    [void](Invoke-LoggedNative -FilePath $chkdsk -Arguments 'C: /scan' -Name 'chkdsk_c_scan' -TimeoutMinutes 120)

    $sfcScan = Invoke-LoggedNative -FilePath $sfc -Arguments '/scannow' -Name 'sfc_scannow' -TimeoutMinutes 180
    $sfcText = Get-OutputText -Result $sfcScan
    if ($sfcScan.ExitCode -ne 0 -or $sfcText -match 'could not perform the requested operation|Windows Resource Protection could not') {
        Write-RepairStatus 'SFC scannow failed; rechecking pending servicing and retrying after service refresh.' 'WARN'
        Ensure-ServiceUsable -Name 'TrustedInstaller' -StartupType 'Manual' -Start
        Wait-ExternalServicing
        Assert-NoPendingServicingOrInstallResume
        $sfcScan = Invoke-LoggedNative -FilePath $sfc -Arguments '/scannow' -Name 'sfc_scannow_retry' -TimeoutMinutes 180
    }
    if ($sfcScan.ExitCode -ne 0) {
        throw "SFC scannow failed after retry. Exit=$($sfcScan.ExitCode). Run log: $Script:LogPath"
    }

    $check = Invoke-LoggedNative -FilePath $dism -Arguments '/Online /Cleanup-Image /CheckHealth' -Name 'dism_checkhealth' -TimeoutMinutes 60
    if ($check.ExitCode -ne 0) {
        throw "DISM CheckHealth verification failed. Exit=$($check.ExitCode). Run log: $Script:LogPath"
    }

    $verify = Invoke-LoggedNative -FilePath $sfc -Arguments '/verifyonly' -Name 'sfc_verifyonly' -TimeoutMinutes 120
    $verifyText = Get-OutputText -Result $verify
    if ($verify.ExitCode -ne 0 -or $verifyText -notmatch 'did not find any integrity violations') {
        throw "SFC verifyonly did not prove a clean system. Exit=$($verify.ExitCode). Run log: $Script:LogPath"
    }

    Remove-ResumeTask
    Write-RepairStatus 'WINDOWS_SERVICING_REPAIR_STATUS=FIXED' 'PASS'
    Write-RepairStatus "SCRIPT_PATH=$PSCommandPath" 'PASS'
}

New-RepairDirectory
'' | Out-File -LiteralPath $Script:LogPath -Encoding UTF8
Write-RepairStatus "Windows servicing repair script starting. Resume=$Resume Path=$PSCommandPath"
try {
    Start-Transcript -LiteralPath $Script:TranscriptPath -Force | Out-Null
} catch {
    Write-RepairStatus "Transcript could not start: $($_.Exception.Message)" 'WARN'
}

try {
    if (-not (Test-IsAdmin)) {
        Write-RepairStatus 'Not elevated; relaunching this script with RunAs so DISM/SFC can repair Windows.' 'WARN'
        $ps5 = Get-SystemTool 'WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $ps5 -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") -Verb RunAs | Out-Null
        exit 1223
    }

    Invoke-RepairSequence
    exit 0
} catch {
    Write-RepairStatus $_.Exception.Message 'ERROR'
    Write-RepairStatus "WINDOWS_SERVICING_REPAIR_STATUS=FAILED log=$Script:LogPath" 'ERROR'
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
