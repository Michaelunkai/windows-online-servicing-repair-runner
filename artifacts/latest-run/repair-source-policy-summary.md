# Latest Run Policy Evidence

The development run saved the prior Windows repair-source policy before opening Windows Update as a DISM component repair source.

Observed relevant values before the script adjusted policy:

- `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\NoAutoUpdate = 1`
- `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\AUOptions = 1`
- `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing\CountryCode = IL`

The full registry object dump was intentionally not packaged because it contained noisy provider metadata and no useful project logic.
