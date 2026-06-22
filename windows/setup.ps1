[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^ssh-(ed25519|rsa|ecdsa) ')]
  [string]$MacPublicKey,

  [string]$AllowedUser = $env:USERNAME,
  [string]$RepoPath = (Join-Path $env:USERPROFILE 'winver'),
  [switch]$EnableAutoUpdate,
  [switch]$SkipFirewall,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Step {
  param([string]$Message)
  Write-Host "[winver] $Message" -ForegroundColor Cyan
}

function Invoke-Winver {
  param([string]$Message, [scriptblock]$Action)
  Write-Step $Message
  if ($DryRun) { return }
  & $Action
}

function Assert-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this setup from an elevated PowerShell window."
  }
}

function Set-SshdConfigValue {
  param(
    [string]$Path,
    [string]$Key,
    [string]$Value
  )

  $lines = if (Test-Path $Path) { Get-Content $Path } else { @() }
  $matchIndex = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*Match\s+') {
      $matchIndex = $i
      break
    }
  }

  if ($matchIndex -ge 0) {
    $globalLines = if ($matchIndex -eq 0) { @() } else { @($lines[0..($matchIndex - 1)]) }
    $matchLines = @($lines[$matchIndex..($lines.Count - 1)])
  } else {
    $globalLines = @($lines)
    $matchLines = @()
  }

  $pattern = "^\s*#?\s*$([regex]::Escape($Key))\s+"
  $replacement = "$Key $Value"
  $found = $false
  $updatedGlobal = foreach ($line in $globalLines) {
    if ($line -match $pattern) {
      $found = $true
      $replacement
    } else {
      $line
    }
  }
  if (-not $found) { $updatedGlobal += $replacement }
  $updated = @($updatedGlobal) + @($matchLines)
  Set-Content -Path $Path -Value $updated -Encoding ascii
}

Assert-Admin

$sshDir = Join-Path $env:USERPROFILE '.ssh'
$authorizedKeys = Join-Path $sshDir 'authorized_keys'
$programDataSsh = Join-Path $env:ProgramData 'ssh'
$adminKeys = Join-Path $programDataSsh 'administrators_authorized_keys'
$sshdConfig = Join-Path $programDataSsh 'sshd_config'
$winverHome = Join-Path $env:USERPROFILE '.winver'
$logRoot = Join-Path $winverHome 'logs'

Invoke-Winver "Installing OpenSSH Server if needed" {
  $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
  if ($capability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
  }
}

Invoke-Winver "Creating worker folders" {
  New-Item -ItemType Directory -Force -Path $sshDir, $programDataSsh, $winverHome, $logRoot | Out-Null
}

Invoke-Winver "Adding Mac SSH public key" {
  if (-not (Test-Path $authorizedKeys)) { New-Item -ItemType File -Path $authorizedKeys -Force | Out-Null }
  $existing = Get-Content $authorizedKeys -ErrorAction SilentlyContinue
  if ($existing -notcontains $MacPublicKey) { Add-Content -Path $authorizedKeys -Value $MacPublicKey }

  if (-not (Test-Path $adminKeys)) { New-Item -ItemType File -Path $adminKeys -Force | Out-Null }
  $existingAdmin = Get-Content $adminKeys -ErrorAction SilentlyContinue
  if ($existingAdmin -notcontains $MacPublicKey) { Add-Content -Path $adminKeys -Value $MacPublicKey }

  icacls $sshDir /inheritance:r /grant "$($env:USERNAME):(OI)(CI)F" /remove "Users" "Authenticated Users" | Out-Null
  icacls $authorizedKeys /inheritance:r /grant "$($env:USERNAME):F" /remove "Users" "Authenticated Users" | Out-Null
  icacls $adminKeys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" /remove "Users" "Authenticated Users" | Out-Null
}

Invoke-Winver "Hardening OpenSSH config" {
  Set-SshdConfigValue -Path $sshdConfig -Key 'PubkeyAuthentication' -Value 'yes'
  Set-SshdConfigValue -Path $sshdConfig -Key 'PasswordAuthentication' -Value 'no'
  Set-SshdConfigValue -Path $sshdConfig -Key 'PermitEmptyPasswords' -Value 'no'
  Set-SshdConfigValue -Path $sshdConfig -Key 'AllowUsers' -Value $AllowedUser
}

Invoke-Winver "Starting sshd" {
  Set-Service -Name sshd -StartupType Automatic
  Start-Service -Name sshd
  Restart-Service -Name sshd
}

if (-not $SkipFirewall) {
  Invoke-Winver "Restricting SSH firewall access to Tailscale addresses" {
    Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -Name 'Winver-SSHD-Tailscale' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule `
      -Name 'Winver-SSHD-Tailscale' `
      -DisplayName 'Winver SSH (Tailscale only)' `
      -Enabled True `
      -Direction Inbound `
      -Protocol TCP `
      -LocalPort 22 `
      -Action Allow `
      -RemoteAddress '100.64.0.0/10' | Out-Null
  }
}

Invoke-Winver "Setting plugged-in server mode" {
  powercfg /change standby-timeout-ac 0 | Out-Null
  powercfg /change hibernate-timeout-ac 0 | Out-Null
  powercfg /change monitor-timeout-ac 10 | Out-Null
}

if ($EnableAutoUpdate) {
  Invoke-Winver "Installing optional auto-update task" {
    & (Join-Path $RepoPath 'windows\agent.ps1') -Install -RepoPath $RepoPath
  }
}

Write-Host ""
Write-Host "winver Surface setup complete." -ForegroundColor Green
Write-Host "From the Mac, run: winver check"
