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
- Opens Windows Update as a repair source and snapshots prior policy state in each run folder.
- Starts servicing/update services needed by DISM repair.
- Retries `RestoreHealth` with cache reset, WinSxS source, discovered install image sources, and Windows Update repair-source refresh.
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
