[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[A-Za-z0-9+/=_-]{32,}$')]
  [string]$AdminKey,

  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an elevated PowerShell window."
  }
}

Assert-Admin

$programRoot = Join-Path $env:ProgramData 'winver'
$auditRoot = Join-Path $programRoot 'audit'
$snapshotRoot = Join-Path $programRoot 'snapshots'
$recoveryRoot = Join-Path $programRoot 'recovery'
$keyPath = Join-Path $programRoot 'admin-signing.key'

Write-Host "[winver] Initializing admin control key" -ForegroundColor Cyan
Write-Host "[winver] Key path: $keyPath"

if ($DryRun) {
  Write-Host "[winver] Dry run only. No files changed."
  exit 0
}

New-Item -ItemType Directory -Force -Path $programRoot, $auditRoot, $snapshotRoot, $recoveryRoot | Out-Null
Set-Content -Path $keyPath -Value $AdminKey.Trim() -Encoding ascii

icacls $programRoot /inheritance:r /grant "Administrators:(OI)(CI)F" /grant "SYSTEM:(OI)(CI)F" | Out-Null
icacls $keyPath /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null

Write-Host "[winver] Admin key stored with Administrators/SYSTEM access only." -ForegroundColor Green

