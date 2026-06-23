$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'scripts\Visible-OnlineRepairV4.ps1'

if (-not (Test-Path -LiteralPath $script)) {
    throw "Missing main script: $script"
}

$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput((Get-Content -LiteralPath $script -Raw), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    $parseErrors | Format-List *
    throw 'PowerShell 5 parser errors found.'
}

$content = Get-Content -LiteralPath $script -Raw
$required = @(
    'Write-Progress',
    'PrintedLineKeys',
    'native duplicate suppression',
    'Invoke-RestoreHealthResilient',
    'Enable-OnlineRepairSource',
    'Reset-WindowsUpdateRepairCache',
    'Test-RecentDismRepairSourceFailure',
    '0x800f0915',
    'UseWUServer',
    'RepairContentServerSource',
    'NeverAttemptPayloadDownload',
    'final preflight',
    'Post100Seconds',
    'phase-post100-timeout',
    'Stop-OwnedProcessTree',
    'DISM CheckHealth fast preflight',
    'dism /online /cleanup-image /restorehealth; $d=$LASTEXITCODE; sfc /scannow'
)

foreach ($needle in $required) {
    if ($content -notlike "*$needle*") {
        throw "Missing required implementation marker: $needle"
    }
}

[pscustomobject]@{
    Status = 'PASS'
    Script = $script
    CheckedMarkers = $required.Count
} | Format-List
