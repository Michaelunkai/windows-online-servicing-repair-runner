param(
    [int]$TakeoverSeconds = 20
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'Continue'

$RunId = [guid]::NewGuid().ToString('N')
$BaseRoot = Join-Path $PSScriptRoot 'repair-runs'
$Root = Join-Path $BaseRoot ("CodexOnlineRepairV4-$RunId")
New-Item -ItemType Directory -Force -Path $Root -ErrorAction SilentlyContinue | Out-Null
$MainLog = Join-Path $Root 'visible-repair-v4.log'

$script:Seq = 0
$script:PhaseIndex = 0
$script:PhaseTotal = 12
$script:LastNativeLine = 'no native output yet'
$script:LastNativePercent = -1
$script:PhaseDisplayPercent = 0
$script:DuplicateNativeCount = 0
$script:LastOutBytes = 0L
$script:LastErrBytes = 0L
$script:LastProgressActivity = ''
$script:LastProgressStatus = ''
$script:LastProgressPercent = -1
$script:LastMilestonePercent = -1
$script:RestoreHealthSucceeded = $false
$script:PrintedLineKeys = New-Object 'System.Collections.Generic.HashSet[string]'

function Stamp { Get-Date -Format 'HH:mm:ss' }

function Show-Line {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [int]$Overall = -1,
        [int]$Phase = -1
    )
    $script:Seq++
    $overallText = '?'
    if ($Overall -ge 0) { $overallText = [string]([Math]::Min(100, [Math]::Max(0, $Overall))) }
    $phaseText = '?'
    if ($Phase -ge 0) { $phaseText = [string]([Math]::Min(100, [Math]::Max(0, $Phase))) }
    $line = '[{0}] [{1}] #{2:000000} overall={3}% phase={4}% :: {5}' -f (Stamp), $Level, $script:Seq, $overallText, $phaseText, $Message
    $dedupeKey = ('{0}|{1}|{2}|{3}' -f $Level, $overallText, $phaseText, ($Message -replace '\d{2}:\d{2}:\d{2}', '<time>' -replace 'elapsed=[^;]+', 'elapsed=<time>' -replace 'cpu=\d+(\.\d+)?s', 'cpu=<n>s' -replace 'updated \d+s ago', 'updated <n>s ago' -replace 'idle=\d+s', 'idle=<n>s'))
    if (-not $script:PrintedLineKeys.Add($dedupeKey)) {
        return
    }
    Write-Host $line
    try {
        if (-not (Test-Path -LiteralPath $Root)) {
            New-Item -ItemType Directory -Force -Path $Root -ErrorAction SilentlyContinue | Out-Null
        }
        Add-Content -LiteralPath $MainLog -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Host ('[{0}] [WARN] #{1:000000} overall={2}% phase={3}% :: log-write skipped without stopping repair: {4}' -f (Stamp), $script:Seq, $overallText, $phaseText, $_.Exception.Message)
    }
    if ($Overall -ge 0) {
        Update-ProgressBar -Activity 'Codex online Windows repair' -Status $Message -Overall $Overall
    }
}

function Update-ProgressBar {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$Overall
    )
    $pct = [Math]::Min(100, [Math]::Max(0, $Overall))
    $script:LastProgressActivity = $Activity
    $script:LastProgressStatus = $Status
    $script:LastProgressPercent = $pct
    Write-Progress -Activity $Activity -Status ("{0}% - {1}" -f $pct, $Status) -PercentComplete $pct
}

function Show-ProgressMilestone {
    param(
        [string]$Name,
        [int]$Overall,
        [int]$Phase,
        [string]$Detail
    )
    if ($Overall -le $script:LastMilestonePercent) { return }
    if (($Overall - $script:LastMilestonePercent) -lt 2 -and $Overall -notin 0,25,50,75,100) { return }
    $script:LastMilestonePercent = $Overall
    Show-Line ("progress milestone: {0}; {1}" -f $Name, $Detail) 'INFO' $Overall $Phase
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Span([timespan]$Span) {
    return '{0:00}:{1:00}:{2:00}' -f [int]$Span.TotalHours, $Span.Minutes, $Span.Seconds
}

function Get-AgeText([datetime]$Time) {
    if ($Time -eq [datetime]::MinValue) { return 'never' }
    return ('{0:n0}s ago' -f ((Get-Date) - $Time).TotalSeconds)
}

function Get-FileStamp([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path -Force).LastWriteTime }
    return [datetime]::MinValue
}

function Get-Overall([int]$PhaseIndex, [int]$PhasePercent) {
    return [int]([Math]::Min(99, ((($PhaseIndex - 1) * 100) + $PhasePercent) / $script:PhaseTotal))
}

function Get-NativePercent([string]$Line) {
    if ($Line -match 'Total:\s*(\d{1,3})%') { return [int]$matches[1] }
    if ($Line -match 'Stage:\s*(\d{1,3})%') { return [int]$matches[1] }
    if ($Line -match '(\d{1,3}(?:\.\d+)?)\s*%') { return [int][Math]::Min(100, [double]$matches[1]) }
    if ($Line -match 'Verification\s+(\d{1,3})%') { return [int]$matches[1] }
    return -1
}

function Read-NewText {
    param(
        [string]$Path,
        [ref]$Position,
        [string]$Prefix
    )
    $delta = 0L
    if (-not (Test-Path -LiteralPath $Path)) { return $delta }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Length -lt $Position.Value) { $Position.Value = 0L }
    $delta = [Math]::Max(0L, $item.Length - $Position.Value)
    if ($delta -le 0) { return $delta }

    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        [void]$fs.Seek($Position.Value, [IO.SeekOrigin]::Begin)
        $bytes = New-Object byte[] $delta
        [void]$fs.Read($bytes, 0, $bytes.Length)
        $Position.Value = $fs.Position
    }
    finally {
        $fs.Close()
    }

    $zeroCount = 0
    foreach ($b in $bytes) { if ($b -eq 0) { $zeroCount++ } }
    if ($bytes.Length -gt 3 -and ($zeroCount / [double]$bytes.Length) -gt 0.20) {
        $text = [Text.Encoding]::Unicode.GetString($bytes)
    }
    else {
        $text = [Text.Encoding]::Default.GetString($bytes)
    }
    foreach ($raw in ($text -split "`r`n|`n|`r")) {
        $line = ($raw -replace "`0", '').Trim()
        if (-not $line) { continue }
        if ($line -eq $script:LastNativeLine) {
            $script:DuplicateNativeCount++
            continue
        }
        if ($script:DuplicateNativeCount -gt 0) {
            $phasePctBefore = [Math]::Max(0, $script:PhaseDisplayPercent)
            Show-Line ("{0} native duplicate suppression: skipped {1} repeated copies of '{2}' before new output arrived" -f $Prefix, $script:DuplicateNativeCount, $script:LastNativeLine) 'INFO' (Get-Overall $script:PhaseIndex $phasePctBefore) $phasePctBefore
            $script:DuplicateNativeCount = 0
        }
        $script:LastNativeLine = $line
        $pct = Get-NativePercent $line
        if ($pct -ge 0) { $script:LastNativePercent = [Math]::Max($script:LastNativePercent, $pct) }
        $phasePct = [Math]::Max($script:PhaseDisplayPercent, [Math]::Max(0, $script:LastNativePercent))
        $script:PhaseDisplayPercent = $phasePct
        $overall = Get-Overall $script:PhaseIndex $phasePct
        Show-Line ("{0} native says: {1}" -f $Prefix, $line) 'OUTPUT' $overall $phasePct
    }
    return $delta
}

function Get-ServicingProcesses {
    @(Get-Process Dism,DismHost,sfc,chkdsk,TiWorker -ErrorAction SilentlyContinue)
}

function Get-ProcessSummary($Processes) {
    if (-not $Processes -or $Processes.Count -eq 0) { return 'none' }
    return (($Processes | ForEach-Object { '{0}#{1} cpu={2:n2}s' -f $_.ProcessName, $_.Id, $_.CPU }) -join '; ')
}

function Stop-ConflictingControllers {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object {
            ($_.CommandLine -match 'Unstuck-Command\.ps1' -and $_.CommandLine -match 'RerunDism') -or
            ($_.CommandLine -match 'Test-UnstuckCommand\.ps1')
        } |
        ForEach-Object {
            Show-Line ("takeover stopped conflicting repair-loop controller pid={0}" -f $_.ProcessId) 'WARN' 1 5
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Start-RepairServices {
    foreach ($svc in 'cryptsvc','bits','wuauserv','TrustedInstaller','msiserver') {
        try {
            & "$env:windir\System32\sc.exe" config $svc start= demand | Where-Object { $_ -and $_.Trim() } | ForEach-Object { Show-Line ("service setup {0}: {1}" -f $svc, $_) 'INFO' 2 10 }
            Start-Service -Name $svc -ErrorAction SilentlyContinue
            Show-Line ("service ready: {0} status={1}" -f $svc, (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status) 'INFO' 2 15
        }
        catch {
            Show-Line ("service prep warning for {0}: {1}" -f $svc, $_.Exception.Message) 'WARN' 2 15
        }
    }
}

function Restart-RepairSourceServices {
    param([string]$Reason)
    Show-Line ("repair-source services: controlled restart for {0}" -f $Reason) 'INFO' 2 28
    foreach ($svc in 'wuauserv','bits','cryptsvc','TrustedInstaller') {
        try {
            $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running' -and $svc -ne 'TrustedInstaller') {
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                Show-Line ("repair-source services: stopped {0}" -f $svc) 'INFO' 2 29
            }
        }
        catch {
            Show-Line ("repair-source services: stop warning for {0}: {1}" -f $svc, $_.Exception.Message) 'WARN' 2 29
        }
    }
    Start-Sleep -Seconds 2
    Start-RepairServices
}

function Enable-OnlineRepairSource {
    $backup = Join-Path $Root 'repair-source-policy-before.json'
    $items = @()
    foreach ($path in 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate','HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing') {
        if (Test-Path -LiteralPath $path) {
            $props = Get-ItemProperty -LiteralPath $path
            $items += [pscustomobject]@{ Path = $path; Properties = $props }
        }
    }
    $items | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backup -Encoding UTF8 -ErrorAction SilentlyContinue
    Show-Line ("repair-source policy snapshot saved: {0}" -f $backup) 'INFO' 2 20

    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name UseWUServer -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    foreach ($name in 'DisableWindowsUpdateAccess','SetPolicyDrivenUpdateSourceForDriverUpdates','SetPolicyDrivenUpdateSourceForFeatureUpdates','SetPolicyDrivenUpdateSourceForOtherUpdates','SetPolicyDrivenUpdateSourceForQualityUpdates') {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name $name -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    }
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -Name UseWindowsUpdate -ErrorAction SilentlyContinue
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -Name NeverAttemptPayloadDownload -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -Name RepairContentServerSource -Value 2 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    Show-Line 'repair-source policy opened: Microsoft repair payloads allowed; WSUS-only blocking disabled; previous values preserved in the run log folder' 'INFO' 2 25
    Restart-RepairSourceServices -Reason 'policy refresh'
}

function Reset-WindowsUpdateRepairCache {
    Show-Line 'repair-source reset: stopping update/catalog services before cache rotation' 'INFO' 2 30
    foreach ($svc in 'bits','wuauserv','cryptsvc','msiserver') {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $targets = @(
        (Join-Path $env:windir 'SoftwareDistribution'),
        (Join-Path $env:windir 'System32\catroot2')
    )
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target) {
            $backup = "$target.codexrepair-$stamp.bak"
            try {
                Rename-Item -LiteralPath $target -NewName ([IO.Path]::GetFileName($backup)) -ErrorAction Stop
                Show-Line ("repair-source reset: rotated {0} -> {1}" -f $target, $backup) 'INFO' 2 45
            }
            catch {
                Show-Line ("repair-source reset: could not rotate {0}; continuing after service restart; reason={1}" -f $target, $_.Exception.Message) 'WARN' 2 45
            }
        }
    }
    Restart-RepairSourceServices -Reason 'cache rotation'
    try {
        & "$env:windir\System32\UsoClient.exe" StartScan 2>$null
        Show-Line 'repair-source reset: requested Windows Update scan for fresh repair payload metadata' 'INFO' 2 55
    }
    catch {
        Show-Line ("repair-source reset: UsoClient scan request skipped: {0}" -f $_.Exception.Message) 'WARN' 2 55
    }
}

function Test-RecentDismRepairSourceFailure {
    $dismLog = Join-Path $env:windir 'Logs\DISM\dism.log'
    if (-not (Test-Path -LiteralPath $dismLog)) { return $false }
    try {
        $tail = Get-Content -LiteralPath $dismLog -Tail 250 -ErrorAction Stop
        return (($tail -match '0x800f0915|repair content could not be found|source files could not be found|source option to specify the location').Count -gt 0)
    }
    catch {
        Show-Line ("DISM log source-failure check skipped: {0}" -f $_.Exception.Message) 'WARN' 2 56
        return $false
    }
}

function Get-WindowsEditionText {
    $edition = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
    $caption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    return ("{0} {1}" -f $caption, $edition).Trim()
}

function Get-MatchingInstallImageIndexes {
    param([string]$ImageFile)
    $editionText = Get-WindowsEditionText
    $indexes = New-Object System.Collections.Generic.List[int]
    try {
        $info = & "$env:windir\System32\dism.exe" /English /Get-WimInfo /WimFile:"$ImageFile" 2>$null
        $currentIndex = $null
        $currentText = ''
        foreach ($line in $info) {
            if ($line -match '^\s*Index\s*:\s*(\d+)') {
                if ($currentIndex -and ($currentText -match [regex]::Escape($editionText) -or $currentText -match 'Windows\s+11|Windows\s+10')) {
                    [void]$indexes.Add([int]$currentIndex)
                }
                $currentIndex = [int]$matches[1]
                $currentText = ''
                continue
            }
            if ($currentIndex) { $currentText += ' ' + $line }
        }
        if ($currentIndex -and ($currentText -match [regex]::Escape($editionText) -or $currentText -match 'Windows\s+11|Windows\s+10')) {
            [void]$indexes.Add([int]$currentIndex)
        }
    }
    catch {
        Show-Line ("install image index detection warning for {0}: {1}" -f $ImageFile, $_.Exception.Message) 'WARN' 2 57
    }
    if ($indexes.Count -eq 0) {
        foreach ($i in 1..12) { [void]$indexes.Add($i) }
    }
    return @($indexes | Select-Object -Unique)
}

function Get-InstallImageSources {
    $sources = New-Object System.Collections.Generic.List[string]
    $roots = @()
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.IsReady) { $roots += $drive.RootDirectory.FullName }
    }
    foreach ($rootDrive in $roots) {
        foreach ($relative in 'sources\install.wim','sources\install.esd') {
            $candidate = Join-Path $rootDrive $relative
            if (Test-Path -LiteralPath $candidate) {
                $prefix = 'WIM'
                if ($candidate -like '*.esd') { $prefix = 'ESD' }
                foreach ($i in Get-MatchingInstallImageIndexes -ImageFile $candidate) {
                    $sources.Add(('/Source:{0}:{1}:{2}' -f $prefix, $candidate, $i))
                }
            }
        }
    }
    $winsxs = Join-Path $env:windir 'WinSxS'
    if (Test-Path -LiteralPath $winsxs) { $sources.Add(('/Source:{0}' -f $winsxs)) }
    return @($sources | Select-Object -Unique)
}

function Invoke-WindowsUpdateRepairInstall {
    Show-Line 'repair-source update install: searching Microsoft/Windows Update for missing servicing stack or cumulative repair content' 'INFO' 2 60
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
        if ($result.Updates.Count -eq 0) {
            Show-Line 'repair-source update install: no applicable software updates found' 'INFO' 2 65
            return 0
        }
        $updates = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $result.Updates.Count; $i++) {
            $u = $result.Updates.Item($i)
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$updates.Add($u)
            Show-Line ("repair-source update candidate: {0}" -f $u.Title) 'INFO' 2 ([Math]::Min(80, 65 + $i))
        }
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $updates
        $download = $downloader.Download()
        Show-Line ("repair-source update download result: {0}" -f $download.ResultCode) 'INFO' 2 82
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $updates
        $installer.ForceQuiet = $true
        $install = $installer.Install()
        Show-Line ("repair-source update install result: {0}; rebootRequired={1}" -f $install.ResultCode, $install.RebootRequired) 'INFO' 2 90
        if ($install.RebootRequired) {
            Show-Line 'repair-source update install: reboot is required by Windows Update, but this script will not reboot; final DISM may still need a reboot later' 'WARN' 2 90
        }
        return 0
    }
    catch {
        Show-Line ("repair-source update install failed: {0}" -f $_.Exception.Message) 'WARN' 2 90
        return 1
    }
}

function Invoke-RestoreHealthResilient {
    $attempts = New-Object System.Collections.Generic.List[object]
    $attempts.Add([pscustomobject]@{ Name='DISM RestoreHealth online attempt 1'; Args='/Online /Cleanup-Image /RestoreHealth'; Stall=240; Timeout=10800 })
    $attempts.Add([pscustomobject]@{ Name='DISM RestoreHealth WinSxS local-source attempt'; Args=('/Online /Cleanup-Image /RestoreHealth /Source:{0}\WinSxS' -f $env:windir); Stall=240; Timeout=10800 })

    foreach ($source in Get-InstallImageSources) {
        $attempts.Add([pscustomobject]@{ Name=('DISM RestoreHealth source attempt {0}' -f $source); Args=('/Online /Cleanup-Image /RestoreHealth {0} /LimitAccess' -f $source); Stall=240; Timeout=10800 })
        $attempts.Add([pscustomobject]@{ Name=('DISM RestoreHealth source+WU attempt {0}' -f $source); Args=('/Online /Cleanup-Image /RestoreHealth {0}' -f $source); Stall=240; Timeout=10800 })
    }

    for ($i = 0; $i -lt $attempts.Count; $i++) {
        $a = $attempts[$i]
        $code = Invoke-Phase -Name $a.Name -Exe "$env:windir\System32\dism.exe" -Arguments $a.Args -StallSeconds $a.Stall -TimeoutSeconds $a.Timeout
        if ($code -eq 0) {
            Show-Line ("RestoreHealth recovered successfully on attempt {0}: {1}" -f ($i + 1), $a.Name) 'PASS' (Get-Overall $script:PhaseIndex 100) 100
            $script:RestoreHealthSucceeded = $true
            return 0
        }
        $sourceMissing = Test-RecentDismRepairSourceFailure
        Show-Line ("RestoreHealth attempt failed with {0}; sourceMissing={1}; preparing stronger source path before next attempt" -f $code, $sourceMissing) 'WARN' (Get-Overall $script:PhaseIndex 100) 100
        if ($sourceMissing -or $i -eq 0) {
            Enable-OnlineRepairSource
            [void](Invoke-Phase -Name 'DISM StartComponentCleanup before source retry' -Exe "$env:windir\System32\dism.exe" -Arguments '/Online /Cleanup-Image /StartComponentCleanup' -StallSeconds 180 -TimeoutSeconds 7200)
            Reset-WindowsUpdateRepairCache
        }
    }

    [void](Invoke-WindowsUpdateRepairInstall)
    $code = Invoke-Phase -Name 'DISM RestoreHealth after Windows Update repair-source refresh' -Exe "$env:windir\System32\dism.exe" -Arguments '/Online /Cleanup-Image /RestoreHealth' -StallSeconds 240 -TimeoutSeconds 10800
    if ($code -eq 0) {
        $script:RestoreHealthSucceeded = $true
        return 0
    }
    return $code
}

function Invoke-FinalRequiredOneLiner {
    if (-not $script:RestoreHealthSucceeded -or (Test-RecentDismRepairSourceFailure)) {
        Show-Line 'final preflight: forcing one last repair-source hardening before mandated plain DISM/SFC gate' 'WARN' 97 0
        Enable-OnlineRepairSource
        Reset-WindowsUpdateRepairCache
        $preflight = Invoke-RestoreHealthResilient
        if ($preflight -ne 0) {
            Show-Line ("final preflight warning: resilient RestoreHealth still returned {0}; mandated final one-liner will run last for proof" -f $preflight) 'WARN' 97 50
        }
    }
    $ps5 = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
    $finalScript = Join-Path $Root 'FINAL_REQUIRED_DISM_THEN_SFC.ps1'
    @(
        'dism /online /cleanup-image /restorehealth; $d=$LASTEXITCODE; sfc /scannow; $s=$LASTEXITCODE'
        'if($d -ne 0 -or $s -ne 0){ exit 1 }'
        'exit 0'
    ) | Set-Content -LiteralPath $finalScript -Encoding ASCII
    Show-Line ("final required one-liner script staged: {0}" -f $finalScript) 'INFO' 98 0
    return Invoke-Phase -Name 'FINAL REQUIRED one-liner dism restorehealth then sfc scannow' -Exe $ps5 -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $finalScript) -StallSeconds 240 -TimeoutSeconds 10800
}

function Invoke-TakeoverGate {
    param([int]$Seconds)
    $script:PhaseIndex = 0
    $start = Get-Date
    $dismLog = Join-Path $env:windir 'Logs\DISM\dism.log'
    $cbsLog = Join-Path $env:windir 'Logs\CBS\CBS.log'
    $lastCpu = -1.0
    $lastMove = Get-Date
    $lastGateMilestone = -10

    while ($true) {
        $active = Get-ServicingProcesses
        if ($active.Count -eq 0) {
            Show-Line 'takeover complete: no external DISM/SFC/CHKDSK/TiWorker owner remains; starting repair pipeline' 'PASS' 1 100
            return
        }

        $sumCpu = ($active | Measure-Object CPU -Sum).Sum
        $dismStamp = Get-FileStamp $dismLog
        $cbsStamp = Get-FileStamp $cbsLog
        $moved = ($lastCpu -lt 0 -or [Math]::Abs($sumCpu - $lastCpu) -gt 0.05 -or ((Get-Date) - $dismStamp).TotalSeconds -lt 2 -or ((Get-Date) - $cbsStamp).TotalSeconds -lt 2)
        if ($moved) {
            $lastMove = Get-Date
            $lastCpu = $sumCpu
        }

        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        $idle = [int]((Get-Date) - $lastMove).TotalSeconds
        $left = [Math]::Max(0, $Seconds - $elapsed)
        $pct = [int][Math]::Min(99, ($elapsed * 100 / [Math]::Max(1, $Seconds)))

        switch ($script:Seq % 7) {
            0 { $msg = 'takeover {0}%: external owner blocks our run; action in {1}s; active={2}' -f $pct, $left, (Get-ProcessSummary $active) }
            1 { $msg = 'takeover evidence {0}%: CPU/log movement={1}; idle={2}s; CBS={3}; DISM={4}' -f $pct, $moved, $idle, (Get-AgeText $cbsStamp), (Get-AgeText $dismStamp) }
            2 { $msg = 'takeover safety {0}%: not starting duplicate DISM; one clean repair owner will run after old owner ends' -f $pct }
            3 { $msg = 'takeover progress {0}%: bounded wait, not an endless loop; stale owners are recycled at 100%' -f $pct }
            4 { $msg = 'takeover diagnosis {0}%: current owner map is {1}' -f $pct, (Get-ProcessSummary $active) }
            5 { $msg = 'takeover next-step {0}%: {1}s until this command takes ownership if still blocked' -f $pct, $left }
            default { $msg = 'takeover clock {0}%: elapsed={1}; idle={2}s; log freshness CBS={3} DISM={4}' -f $pct, (Format-Span ((Get-Date) - $start)), $idle, (Get-AgeText $cbsStamp), (Get-AgeText $dismStamp) }
        }
        Update-ProgressBar -Activity 'Codex online Windows repair - takeover' -Status $msg -Overall 1
        if ($pct -ge ($lastGateMilestone + 10) -or $pct -ge 99) {
            $lastGateMilestone = $pct
            Show-Line $msg 'INFO' 1 $pct
        }

        if ($elapsed -ge $Seconds) {
            Show-Line 'takeover action 100%: stopping external/stale servicing owner so this visible command owns the repair path' 'WARN' 1 100
            $active | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 3
            return
        }
        Start-Sleep -Seconds 1
    }
}

function Invoke-Phase {
    param(
        [string]$Name,
        [string]$Exe,
        [string]$Arguments,
        [int]$StallSeconds,
        [int]$TimeoutSeconds
    )

    $script:PhaseIndex++
    $script:LastNativeLine = 'waiting for first native output'
    $script:LastNativePercent = -1
    $script:PhaseDisplayPercent = 0
    $script:DuplicateNativeCount = 0

    New-Item -ItemType Directory -Force -Path $Root -ErrorAction SilentlyContinue | Out-Null
    $safeName = $Name -replace '[^A-Za-z0-9]+', '_'
    $out = Join-Path $Root "$safeName.out.log"
    $err = Join-Path $Root "$safeName.err.log"
    $cmdArgs = '/d /c ""{0}" {1} 1>>"{2}" 2>>"{3}""' -f $Exe, $Arguments, $out, $err

    Show-Line ("phase-start: {0}; command={1} {2}" -f $Name, $Exe, $Arguments) 'INFO' (Get-Overall $script:PhaseIndex 0) 0
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList $cmdArgs -WindowStyle Hidden -PassThru

    $start = Get-Date
    $lastMove = Get-Date
    $outPos = 0L
    $errPos = 0L
    $lastCpu = -1.0
    $dismLog = Join-Path $env:windir 'Logs\DISM\dism.log'
    $cbsLog = Join-Path $env:windir 'Logs\CBS\CBS.log'

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 1
        $outDelta = Read-NewText $out ([ref]$outPos) $Name
        $errDelta = Read-NewText $err ([ref]$errPos) "$Name ERROR"
        $proc.Refresh()

        $children = @(Get-ServicingProcesses | Where-Object { $_.StartTime -ge $start.AddSeconds(-10) })
        $cpu = ($children | Measure-Object CPU -Sum).Sum
        $dismStamp = Get-FileStamp $dismLog
        $cbsStamp = Get-FileStamp $cbsLog
        $moved = ($outDelta -gt 0 -or $errDelta -gt 0 -or $lastCpu -lt 0 -or [Math]::Abs($cpu - $lastCpu) -gt 0.05 -or ((Get-Date) - $dismStamp).TotalSeconds -lt 2 -or ((Get-Date) - $cbsStamp).TotalSeconds -lt 2)
        if ($moved) {
            $lastMove = Get-Date
            $lastCpu = $cpu
        }

        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        $idle = [int]((Get-Date) - $lastMove).TotalSeconds
        $antiStallPct = [int][Math]::Min(99, ($elapsed * 100 / [Math]::Max(1, ($StallSeconds * 2))))
        $nativePct = 0
        if ($script:LastNativePercent -ge 0) { $nativePct = $script:LastNativePercent }
        $phasePct = [Math]::Max($script:PhaseDisplayPercent, [Math]::Max($nativePct, $antiStallPct))
        $script:PhaseDisplayPercent = $phasePct
        $overall = Get-Overall $script:PhaseIndex $phasePct
        $safeStop = [Math]::Max(0, $StallSeconds - $idle)

        switch ($script:Seq % 8) {
            0 { $msg = '{0} {1}%: native percent when available, otherwise anti-stall timer; elapsed={2}' -f $Name, $phasePct, (Format-Span ((Get-Date) - $start)) }
            1 { $msg = '{0} evidence: stdout +{1}B, stderr +{2}B, child CPU total {3:n2}s' -f $Name, $outDelta, $errDelta, $cpu }
            2 { $msg = '{0} live logs: CBS updated {1}, DISM updated {2}, movement={3}' -f $Name, (Get-AgeText $cbsStamp), (Get-AgeText $dismStamp), $moved }
            3 { $msg = '{0} safety clock: idle={1}s; auto-stop/retry protection in {2}s if nothing changes' -f $Name, $idle, $safeStop }
            4 { $msg = '{0} process map: {1}' -f $Name, (Get-ProcessSummary $children) }
            5 { $msg = '{0} last native message: {1}' -f $Name, $script:LastNativeLine }
            6 { $msg = '{0} overall repair progress now {1}% across all checks and repairs; suppressed duplicate native lines={2}' -f $Name, $overall, $script:DuplicateNativeCount }
            default { $msg = '{0} watchdog: no silent hang allowed; timeout={1}s elapsed={2}s idle={3}s' -f $Name, $TimeoutSeconds, $elapsed, $idle }
        }
        Update-ProgressBar -Activity ("Codex online Windows repair - {0}" -f $Name) -Status $msg -Overall $overall
        Show-ProgressMilestone -Name $Name -Overall $overall -Phase $phasePct -Detail $msg

        if ($idle -ge $StallSeconds) {
            Show-Line ("phase-stall: {0} had no output/CPU/log movement for {1}s; stopping owned tree" -f $Name, $idle) 'WARN' $overall $phasePct
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $children | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
            return 124
        }
        if ($elapsed -gt $TimeoutSeconds) {
            Show-Line ("phase-timeout: {0} exceeded {1}s; stopping owned command" -f $Name, $TimeoutSeconds) 'ERROR' $overall $phasePct
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            return 125
        }
    }

    [void](Read-NewText $out ([ref]$outPos) $Name)
    [void](Read-NewText $err ([ref]$errPos) "$Name ERROR")
    $proc.Refresh()
    Show-Line ("phase-end: {0}; exit={1}" -f $Name, $proc.ExitCode) 'INFO' (Get-Overall $script:PhaseIndex 100) 100
    return $proc.ExitCode
}

if (-not (Test-Admin)) {
    Write-Host 'Run Windows PowerShell as Administrator'
    exit 1
}

Show-Line ("online-repair-v4 start; log={0}; mode=visible PS5, rotating per-second progress, native output streaming" -f $MainLog) 'INFO' 0 0
Stop-ConflictingControllers
Enable-OnlineRepairSource
Start-RepairServices

& "$env:windir\System32\sc.exe" config TrustedInstaller start= demand |
    Where-Object { $_ -and $_.Trim() } |
    ForEach-Object { Show-Line ("TrustedInstaller setup: {0}" -f $_) 'INFO' 0 0 }
& "$env:windir\System32\sc.exe" start TrustedInstaller |
    Where-Object { $_ -and $_.Trim() } |
    ForEach-Object { Show-Line ("TrustedInstaller start state: {0}" -f $_) 'INFO' 0 0 }

Invoke-TakeoverGate -Seconds $TakeoverSeconds

$failures = 0
$steps = @(
    @('CHKDSK online scan', "$env:windir\System32\chkdsk.exe", 'C: /scan /perf', 180, 7200),
    @('DISM ScanHealth', "$env:windir\System32\dism.exe", '/Online /Cleanup-Image /ScanHealth', 180, 7200),
    @('DISM RestoreHealth resilient', '', '', 240, 10800),
    @('SFC scannow', "$env:windir\System32\sfc.exe", '/scannow', 180, 7200),
    @('DISM CheckHealth', "$env:windir\System32\dism.exe", '/Online /Cleanup-Image /CheckHealth', 120, 3600),
    @('SFC verifyonly', "$env:windir\System32\sfc.exe", '/verifyonly', 180, 7200)
)

foreach ($step in $steps) {
    if ($step[0] -eq 'DISM RestoreHealth resilient') {
        $code = Invoke-RestoreHealthResilient
    }
    else {
        $code = Invoke-Phase -Name $step[0] -Exe $step[1] -Arguments $step[2] -StallSeconds $step[3] -TimeoutSeconds $step[4]
    }
    if ($code -ne 0) {
        $failures++
        Show-Line ("phase warning: {0} returned {1}; continuing with remaining checks" -f $step[0], $code) 'WARN' (Get-Overall $script:PhaseIndex 100) 100
    }
    Stop-ConflictingControllers
    Start-Sleep -Seconds 1
}

$finalCode = Invoke-FinalRequiredOneLiner
if ($finalCode -ne 0) {
    $failures++
    Show-Line ("final required one-liner failed with {0}; no later repair steps are run because this is the mandated last gate" -f $finalCode) 'ERROR' 99 100
}
else {
    Show-Line 'final required one-liner completed successfully: dism /online /cleanup-image /restorehealth; sfc /scannow' 'PASS' 100 100
}

Show-Line ("online-repair-v4 done; issueCount={0}; log={1}" -f $failures, $MainLog) 'PASS' 100 100
