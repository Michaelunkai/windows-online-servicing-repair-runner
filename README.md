# Windows Online Servicing Repair Runner

PowerShell 5 compatible Windows servicing repair runner for DISM, SFC, CHKDSK, Windows Update repair-source preparation, and a final literal DISM/SFC verification gate.

## Main Script

```powershell
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Visible-OnlineRepairV4.ps1
```

Run from an elevated Windows PowerShell 5 window. The script intentionally performs real system maintenance and can stop stale DISM/SFC/CHKDSK/TiWorker owners before taking over the repair path.

## Behavior

- Uses a real-time `Write-Progress` bar from start to finish.
- Suppresses repeated native output and prints unique milestones, warnings, phase starts, phase ends, and changed native output.
- Uses a bounded post-100% guard so a native tool that displays 100% but does not exit is stopped and the next repair path continues.
- Opens Windows Update as a repair source and snapshots prior policy state in each run folder.
- Specifically detects DISM `0x800f0915` / missing repair content failures, disables WSUS-only repair-source blocking, and retries after cache/service refresh.
- Starts servicing/update services needed by DISM repair.
- Avoids the slow full `ScanHealth` phase in the normal path; uses fast `CheckHealth` plus resilient `RestoreHealth`, cache reset, WinSxS source, discovered install image sources, and Windows Update repair-source refresh.
- Runs the final required one-liner as the last gate:

```powershell
dism /online /cleanup-image /restorehealth; sfc /scannow
```

## Project Layout

- `scripts/Visible-OnlineRepairV4.ps1` - current main runner.
- `scripts/Repair-WindowsServicingStack.legacy.ps1` - earlier broader repair script kept for reference.
- `tests/Test-Project.ps1` - non-destructive parser/static validation.
- `artifacts/latest-run/` - copied evidence from the latest development run.

## Verification

```powershell
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Project.ps1
```

The test validates PowerShell 5 parsing and required guardrails without running DISM/SFC.
