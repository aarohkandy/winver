[CmdletBinding()]
param(
  [string]$RepoPath = (Join-Path $env:USERPROFILE 'winver'),
  [switch]$Json
)

$checks = New-Object System.Collections.Generic.List[object]
$nextSteps = New-Object System.Collections.Generic.List[string]

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

function Add-NextStep {
  param([string]$Step)
  if (-not $nextSteps.Contains($Step)) { $nextSteps.Add($Step) }
}

function Test-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-Admin
$tailscale = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
$firewall = Get-NetFirewallRule -Name 'Winver-SSHD-Tailscale' -ErrorAction SilentlyContinue
$sshdConfig = Join-Path $env:ProgramData 'ssh\sshd_config'
$authorizedKeys = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
$adminKey = Join-Path $env:ProgramData 'winver\admin-signing.key'
$tailscaleExe = 'C:\Program Files\Tailscale\tailscale.exe'
$tailscaleStatus = if (Test-Path $tailscaleExe) {
  try { & $tailscaleExe status 2>$null | Select-Object -First 8 | Out-String } catch { $_.Exception.Message }
} else {
  'Tailscale CLI not found at expected path'
}
$tailscaleIp = if (Test-Path $tailscaleExe) {
  try { (& $tailscaleExe ip -4 2>$null | Select-Object -First 1) } catch { '' }
} else {
  ''
}
$sshListening = $false
try {
  $sshListening = [bool](Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)
} catch {
  $sshListening = $false
}
$authorizedKeyCount = 0
if (Test-Path $authorizedKeys) {
  $authorizedKeyCount = @((Get-Content $authorizedKeys -ErrorAction SilentlyContinue) | Where-Object { $_ -match '^ssh-' }).Count
}
$authorizedKeysAllowsSystem = $false
if (Test-Path $authorizedKeys) {
  try {
    $authorizedKeysAllowsSystem = [bool]((Get-Acl $authorizedKeys).Access | Where-Object {
      $_.IdentityReference -match 'SYSTEM' -and
      $_.FileSystemRights.ToString() -match 'FullControl|Read|ReadAndExecute' -and
      $_.AccessControlType -eq 'Allow'
    })
  } catch {
    $authorizedKeysAllowsSystem = $false
  }
}

Add-Check 'Windows' $true ([System.Environment]::OSVersion.VersionString)
Add-Check 'Admin shell' $isAdmin ($(if ($isAdmin) { 'running elevated' } else { 'not elevated' }))
Add-Check 'Tailscale service' ([bool]$tailscale) ($(if ($tailscale) { $tailscale.Status } else { 'missing' }))
Add-Check 'Tailscale IP' ([bool]$tailscaleIp) ($(if ($tailscaleIp) { $tailscaleIp } else { 'missing or logged out' }))
Add-Check 'OpenSSH service' ([bool]$sshd -and $sshd.Status -eq 'Running') ($(if ($sshd) { $sshd.Status } else { 'missing' }))
Add-Check 'Port 22 listening' $sshListening ($(if ($sshListening) { 'listening locally' } else { 'not listening' }))
Add-Check 'Git' (Has-Command git) ($(if (Has-Command git) { (git --version) } else { 'missing' }))
Add-Check 'Codex' (Has-Command codex) ($(if (Has-Command codex) { 'available' } else { 'missing or not on PATH' }))
Add-Check 'Repo path' (Test-Path $RepoPath) $RepoPath
Add-Check 'authorized_keys' ($authorizedKeyCount -gt 0) ($(if ($authorizedKeyCount -gt 0) { "$authorizedKeyCount SSH public key(s)" } else { "missing or empty: $authorizedKeys" }))
Add-Check 'authorized_keys SYSTEM ACL' $authorizedKeysAllowsSystem ($(if ($authorizedKeysAllowsSystem) { 'SYSTEM can read key file' } else { 'SYSTEM cannot read key file' }))
Add-Check 'SSH firewall' ([bool]$firewall) ($(if ($firewall) { 'Winver-SSHD-Tailscale exists' } else { 'missing' }))
Add-Check 'Admin signing key' (Test-Path $adminKey) ($(if (Test-Path $adminKey) { $adminKey } else { 'optional, not initialized' }))

if (Test-Path $sshdConfig) {
  $config = Get-Content $sshdConfig -Raw
  Add-Check 'Password SSH disabled' ($config -match '(?m)^\s*PasswordAuthentication\s+no\s*$') 'PasswordAuthentication no'
  Add-Check 'Key SSH enabled' ($config -match '(?m)^\s*PubkeyAuthentication\s+yes\s*$') 'PubkeyAuthentication yes'
} else {
  Add-Check 'sshd_config' $false $sshdConfig
}

$setupCommand = '.\windows\setup.ps1 -MacPublicKey "PASTE_THE_MAC_PUBLIC_KEY_FROM_MAC"'
$setupNeeded = (-not $sshd -or $sshd.Status -ne 'Running' -or -not $sshListening -or $authorizedKeyCount -eq 0 -or -not $authorizedKeysAllowsSystem -or -not $firewall -or -not (Test-Path $sshdConfig))

if ($setupNeeded -and -not $isAdmin) {
  Add-NextStep 'Open PowerShell as Administrator, then run this doctor again.'
}
if (-not $tailscale -or $tailscale.Status -ne 'Running' -or -not $tailscaleIp) {
  Add-NextStep 'Open Tailscale on Windows and sign in. Then confirm this machine is named winver.'
}
if (-not (Test-Path $RepoPath)) {
  Add-NextStep 'Clone the repo: git clone https://github.com/aarohkandy/winver.git $env:USERPROFILE\winver'
}
if ($setupNeeded) {
  Add-NextStep "Run setup in Administrator PowerShell from the repo folder: cd `$env:USERPROFILE\winver; Set-ExecutionPolicy -Scope Process Bypass -Force; $setupCommand"
}
if (-not (Test-Path $adminKey)) {
  Add-NextStep 'Optional deep admin mode is not initialized. If wanted, run: .\windows\admin\init-admin.ps1 -AdminKey "PASTE_THE_ADMIN_KEY_FROM_MAC"'
}

if ($Json) {
  [pscustomobject]@{
    checks = $checks
    nextSteps = $nextSteps
    tailscaleStatus = $tailscaleStatus
  } | ConvertTo-Json -Depth 5
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

Write-Host ""
Write-Host "Tailscale snapshot" -ForegroundColor Cyan
Write-Host "=================="
Write-Host (($tailscaleStatus.Trim()) -replace "`r", '')

Write-Host ""
Write-Host "Password note" -ForegroundColor Cyan
Write-Host "============="
Write-Host "You should not need to share a Windows password with the Mac."
Write-Host "If SSH asks for a password, the Mac key is not installed or sshd is not configured yet."
Write-Host "The only password/PIN you may need is local Windows admin approval to run setup."

Write-Host ""
Write-Host "Next steps" -ForegroundColor Cyan
Write-Host "=========="
if ($nextSteps.Count -eq 0) {
  Write-Host "[ok] Windows side looks ready. Go to the Mac and run: ./bin/winver check" -ForegroundColor Green
} else {
  foreach ($step in $nextSteps) {
    Write-Host "- $step" -ForegroundColor Yellow
  }
}
