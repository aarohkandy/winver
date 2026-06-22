[CmdletBinding()]
param(
  [string]$RepoPath = (Join-Path $env:USERPROFILE 'winver'),
  [switch]$Json
)

$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail
  )
  $checks.Add([pscustomobject]@{
    name = $Name
    ok = $Ok
    detail = $Detail
  })
}

function Has-Command {
  param([string]$Name)
  [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

$tailscale = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
$firewall = Get-NetFirewallRule -Name 'Winver-SSHD-Tailscale' -ErrorAction SilentlyContinue
$sshdConfig = Join-Path $env:ProgramData 'ssh\sshd_config'
$authorizedKeys = Join-Path $env:USERPROFILE '.ssh\authorized_keys'

Add-Check 'Windows' $true ([System.Environment]::OSVersion.VersionString)
Add-Check 'Tailscale service' ([bool]$tailscale) ($(if ($tailscale) { $tailscale.Status } else { 'missing' }))
Add-Check 'OpenSSH service' ([bool]$sshd -and $sshd.Status -eq 'Running') ($(if ($sshd) { $sshd.Status } else { 'missing' }))
Add-Check 'Git' (Has-Command git) ($(if (Has-Command git) { (git --version) } else { 'missing' }))
Add-Check 'Codex' (Has-Command codex) ($(if (Has-Command codex) { 'available' } else { 'missing or not on PATH' }))
Add-Check 'Repo path' (Test-Path $RepoPath) $RepoPath
Add-Check 'authorized_keys' (Test-Path $authorizedKeys) $authorizedKeys
Add-Check 'SSH firewall' ([bool]$firewall) ($(if ($firewall) { 'Winver-SSHD-Tailscale exists' } else { 'missing' }))

if (Test-Path $sshdConfig) {
  $config = Get-Content $sshdConfig -Raw
  Add-Check 'Password SSH disabled' ($config -match '(?m)^\s*PasswordAuthentication\s+no\s*$') 'PasswordAuthentication no'
  Add-Check 'Key SSH enabled' ($config -match '(?m)^\s*PubkeyAuthentication\s+yes\s*$') 'PubkeyAuthentication yes'
} else {
  Add-Check 'sshd_config' $false $sshdConfig
}

if ($Json) {
  $checks | ConvertTo-Json -Depth 4
  exit
}

Write-Host ""
Write-Host "winver doctor" -ForegroundColor Cyan
Write-Host "============="
foreach ($check in $checks) {
  $icon = if ($check.ok) { '[ok]' } else { '[!!]' }
  $color = if ($check.ok) { 'Green' } else { 'Yellow' }
  Write-Host ("{0,-5} {1,-24} {2}" -f $icon, $check.name, $check.detail) -ForegroundColor $color
}

