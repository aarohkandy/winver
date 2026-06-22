[CmdletBinding()]
param(
  [ValidateSet('inventory', 'plan', 'prepare-local')]
  [string]$Action = 'inventory',

  [switch]$Json,
  [switch]$LocalConfirm,
  [string]$OutputRoot = (Join-Path $env:USERPROFILE '.winver\uefi')
)

$ErrorActionPreference = 'Stop'

function Invoke-Safe {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Script,
    $Fallback = $null
  )
  try { & $Script } catch { $Fallback }
}

function Test-RemoteSession {
  [bool]($env:SSH_CLIENT -or $env:SSH_CONNECTION)
}

function Get-SurfaceUefiInventory {
  $computer = Invoke-Safe { Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model } $null
  $product = Invoke-Safe { Get-CimInstance Win32_ComputerSystemProduct | Select-Object Name, Vendor, Version, UUID, IdentifyingNumber } $null
  $bios = Invoke-Safe { Get-CimInstance Win32_BIOS | Select-Object Manufacturer, SMBIOSBIOSVersion, SerialNumber, ReleaseDate } $null
  $isSurface = $false
  $model = ''
  if ($computer) {
    $model = [string]$computer.Model
    $isSurface = ([string]$computer.Manufacturer -match 'Microsoft') -and ($model -match 'Surface')
  }

  $semmLikely = $model -match 'Surface (Pro|Laptop|Book|Studio|Go)'

  [pscustomobject]@{
    capturedAt = (Get-Date).ToString('o')
    isRemoteSession = Test-RemoteSession
    computer = $computer
    product = $product
    bios = $bios
    tpm = Invoke-Safe { Get-Tpm } $null
    secureBoot = Invoke-Safe { Confirm-SecureBootUEFI } $null
    bitlocker = Invoke-Safe { Get-BitLockerVolume | Select-Object MountPoint, ProtectionStatus, VolumeStatus, EncryptionPercentage } @()
    isSurface = $isSurface
    model = $model
    semmLikelySupported = $semmLikely
    surfaceItToolkitPackagePath = Join-Path $OutputRoot 'packages'
    notes = @(
      'Inventory only. This script does not write firmware settings.',
      'SEMM enrollment requires physical confirmation at the Surface.',
      'Keep SEMM certificate private key and recovery/unenroll package offline.'
    )
  }
}

function Write-UefiPlan {
  $inventory = Get-SurfaceUefiInventory
  New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
  $packageRoot = Join-Path $OutputRoot 'packages'
  $planPath = Join-Path $OutputRoot 'surface-uefi-semm-plan.md'
  New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null

  $body = @"
# winver Surface UEFI / SEMM Plan

Generated: $(Get-Date -Format o)
Model: $($inventory.model)
Remote session: $($inventory.isRemoteSession)
Package workspace: $packageRoot

## Guardrails

- This repo does not flash firmware or enroll SEMM remotely.
- Any SEMM enrollment or UEFI lock change must happen while physically present at the Surface.
- Verify BitLocker recovery before changing boot, TPM, Secure Boot, or firmware management settings.
- Keep the SEMM certificate private key and unenroll package offline.

## Prep checklist

1. Install Microsoft Surface IT Toolkit on the Surface or a trusted admin PC.
2. Export or verify BitLocker recovery for the Surface.
3. Create a SEMM certificate and store the private key offline.
4. Use Surface UEFI Configurator to create an enrollment package in:
   $packageRoot
5. Create and separately store an unenroll/recovery package.
6. Run the package locally on the Surface.
7. Physically confirm enrollment using the last two digits of the certificate thumbprint when prompted.
8. Reboot, then run:
   .\windows\admin\uefi.ps1 -Action inventory

## Recommended first firmware policy

- Keep Secure Boot enabled.
- Keep TPM enabled.
- Keep Windows Boot Manager and Internal Storage enabled.
- Avoid locking boot order until recovery media and BitLocker recovery are verified.
- Disable cameras, Bluetooth, or removable boot only if you are sure this Surface will stay server-only.

## Reversal

- Use the SEMM unenroll package generated from the same certificate.
- Do not delete the certificate or private key until unenrollment has been confirmed.
"@

  Set-Content -Path $planPath -Value $body -Encoding utf8
  Write-Host "UEFI/SEMM plan written to: $planPath" -ForegroundColor Green
  Write-Host "Package workspace: $packageRoot"
}

switch ($Action) {
  'inventory' {
    $inventory = Get-SurfaceUefiInventory
    if ($Json) { $inventory | ConvertTo-Json -Depth 8 } else { $inventory | Format-List }
  }
  'plan' {
    Write-UefiPlan
  }
  'prepare-local' {
    if (Test-RemoteSession -and -not $LocalConfirm) {
      throw "prepare-local refuses to run over SSH without -LocalConfirm. Firmware-tier prep should happen at the Surface."
    }
    Write-UefiPlan
    Write-Host "Local prep acknowledged. No firmware settings were changed." -ForegroundColor Yellow
  }
}

