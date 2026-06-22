[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

Write-Host "Applying local break-glass disablement for winver remote access." -ForegroundColor Yellow
Stop-Service sshd
Set-Service sshd -StartupType Disabled
Unregister-ScheduledTask -TaskName 'WinverAutoUpdate' -Confirm:$false
Get-NetFirewallRule -Name 'Winver-SSHD-Tailscale' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
Write-Host "Done. Re-enable manually only after reviewing SECURITY.md." -ForegroundColor Green

