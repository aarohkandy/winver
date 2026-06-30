[CmdletBinding()]
param(
  [ValidateSet('status', 'power', 'services', 'updates', 'defender', 'firewall', 'bitlocker', 'tpm', 'battery', 'thermal', 'server-profile', 'lockdown', 'cooling', 'unlock', 'rollback', 'export-recovery', 'break-glass', 'reboot', 'shutdown', 'admin-shell')]
  [string]$Action = 'status',

  [ValidateSet('DryRun', 'Apply')]
  [string]$Mode = 'DryRun',

  [ValidateSet('status', 'max', 'cool', 'balanced', 'quiet')]
  [string]$CoolingProfile = 'status',

  [string]$RequestId = ([guid]::NewGuid().ToString()),
  [string]$Signature = '',
  [string]$AdminShellCommand = '',
  [switch]$Force,
  [switch]$SkipBitLockerCheck
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'policy.ps1')

$programRoot = Join-Path $env:ProgramData 'winver'
$auditRoot = Join-Path $programRoot 'audit'
$snapshotRoot = Join-Path $programRoot 'snapshots'
$recoveryRoot = Join-Path $programRoot 'recovery'
$auditLog = Join-Path $auditRoot 'admin.jsonl'

function Invoke-Safe {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Script,
    $Fallback = $null
  )
  try { & $Script } catch { $Fallback }
}

function Assert-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Apply-level admin actions require an elevated Administrator session."
  }
}

function Assert-SignedApply {
  if ($Mode -ne 'Apply' -or -not (Test-WinverDangerousAction -Action $Action)) { return }

  $key = Get-WinverAdminKey
  if (-not $key) {
    throw "Missing Windows admin signing key. Run .\windows\admin\init-admin.ps1 from elevated PowerShell."
  }
  if (-not $Signature) {
    throw "Missing admin request signature. Run ./mac/setup-admin-key.sh on the Mac and retry."
  }

  $payload = ConvertTo-WinverSignaturePayload -Action $Action -Mode $Mode -RequestId $RequestId -Command $AdminShellCommand -Profile $CoolingProfile
  if (-not (Test-WinverHmacSignature -Key $key -Payload $payload -Signature $Signature)) {
    throw "Admin request signature did not verify."
  }
}

function Get-ActivePowerSchemeGuid {
  $line = Invoke-Safe { powercfg /getactivescheme } ''
  if ($line -match '([0-9a-fA-F-]{36})') { return $Matches[1] }
  return ''
}

function Get-WinverSystemSnapshot {
  [pscustomobject]@{
    capturedAt = (Get-Date).ToString('o')
    user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    computer = Invoke-Safe { Get-ComputerInfo | Select-Object CsName, WindowsProductName, OsVersion, CsModel, CsManufacturer, CsTotalPhysicalMemory } $null
    bios = Invoke-Safe { Get-CimInstance Win32_BIOS | Select-Object Manufacturer, SMBIOSBIOSVersion, SerialNumber, ReleaseDate } $null
    activePowerScheme = Get-ActivePowerSchemeGuid
    services = Invoke-Safe { Get-Service sshd, Tailscale, wuauserv, WinDefend -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType } @()
    firewall = Invoke-Safe { Get-NetFirewallRule -Name 'Winver-SSHD-Tailscale', 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Select-Object Name, Enabled, Direction, Action } @()
    bitlocker = Invoke-Safe { Get-BitLockerVolume | Select-Object MountPoint, ProtectionStatus, VolumeStatus, EncryptionPercentage, KeyProtector } @()
    tpm = Invoke-Safe { Get-Tpm } $null
    secureBoot = Invoke-Safe { Confirm-SecureBootUEFI } $null
  }
}

function New-WinverSnapshot {
  param([string]$Reason)

  New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $base = Join-Path $snapshotRoot "$stamp-$Reason"
  $jsonPath = "$base.json"
  $rollbackPath = "$base.rollback.ps1"
  $snapshot = Get-WinverSystemSnapshot
  $snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding utf8

  $scheme = if ($snapshot.activePowerScheme) { $snapshot.activePowerScheme } else { 'SCHEME_BALANCED' }
  @"
`$ErrorActionPreference = 'Continue'
Write-Host 'Rolling back winver server profile basics.'
powercfg /setactive $scheme | Out-Null
powercfg /change standby-timeout-ac 30 | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null
powercfg /change monitor-timeout-ac 10 | Out-Null
Write-Host 'Rollback complete. Review $jsonPath for the original captured state.'
"@ | Set-Content -Path $rollbackPath -Encoding utf8

  [pscustomobject]@{
    snapshot = $jsonPath
    rollback = $rollbackPath
  }
}

function Write-Audit {
  param(
    [string]$Result,
    [object]$Detail = $null
  )

  try {
    New-Item -ItemType Directory -Force -Path $auditRoot | Out-Null
    [pscustomobject]@{
      at = (Get-Date).ToString('o')
      requestId = $RequestId
      action = $Action
      mode = $Mode
      result = $Result
      user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
      remote = $env:SSH_CLIENT
      detail = $Detail
    } | ConvertTo-Json -Depth 8 -Compress | Add-Content -Path $auditLog
  } catch {
    Write-Warning "Could not write winver audit log: $($_.Exception.Message)"
  }
}

function Test-BitLockerRecoveryProtector {
  $volumes = Invoke-Safe { Get-BitLockerVolume } @()
  foreach ($volume in $volumes) {
    if ($volume.ProtectionStatus -eq 'On') {
      $hasRecovery = $false
      foreach ($protector in $volume.KeyProtector) {
        if ($protector.KeyProtectorType -match 'Recovery') { $hasRecovery = $true }
      }
      if (-not $hasRecovery) { return $false }
    }
  }
  return $true
}

function Assert-BitLockerPrepared {
  if ($SkipBitLockerCheck) { return }
  if (-not (Test-BitLockerRecoveryProtector)) {
    throw "BitLocker is protected but no recovery protector was detected. Export/verify recovery first or pass -SkipBitLockerCheck."
  }
}

function Show-Object {
  param($Value)
  if ($null -eq $Value) {
    Write-Host "(unavailable)"
  } elseif ($Value -is [string]) {
    Write-Host $Value
  } else {
    $Value | Format-List
  }
}

function Show-Status {
  Write-Host ""
  Write-Host "winver deep admin status" -ForegroundColor Cyan
  Write-Host "========================="
  Show-Object (Get-WinverSystemSnapshot)
}

function Show-ServerProfilePlan {
  [pscustomobject]@{
    mode = $Mode
    changes = @(
      'disable plugged-in sleep',
      'disable plugged-in hibernate timeout',
      'turn display off after a short plugged-in timeout',
      'activate high-performance power profile when available',
      'ensure sshd and Tailscale services start automatically',
      'disable Windows AutoAdminLogon',
      'write snapshot, rollback script, and audit log'
    )
    rollback = 'Run winver admin rollback --apply after reviewing the generated rollback path.'
  } | Format-List
}

function Show-LockdownPlan {
  [pscustomobject]@{
    mode = $Mode
    changes = @(
      'snapshot current state and generate rollback helper',
      'disable plugged-in sleep and hibernate timeouts',
      'turn display off quickly while plugged in',
      'activate high-performance power profile',
      'set AC processor min/max to 100 percent',
      'prefer active cooling on AC when the setting exists',
      'allow wake timers on AC',
      'ignore lid close on AC',
      'auto-start and start sshd/Tailscale',
      'disable AutoAdminLogon',
      'set broad daytime Windows Update active hours'
    )
    heat = 'Designed for plugged-in compute. Hardware thermal throttling still protects the Surface.'
    undo = 'Use winver admin unlock --apply for normal laptop-ish behavior, or winver admin rollback --apply for the latest snapshot rollback helper.'
  } | Format-List
}

function Show-UnlockPlan {
  [pscustomobject]@{
    mode = $Mode
    changes = @(
      'snapshot current state',
      'restore balanced power plan',
      'restore plugged-in display timeout to 10 minutes',
      'restore plugged-in sleep timeout to 30 minutes',
      'allow normal processor scaling on AC',
      'keep sshd/Tailscale available for convenience'
    )
  } | Format-List
}

function Invoke-WinverPowercfg {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  $output = & powercfg @Arguments 2>&1
  $code = $LASTEXITCODE
  $result = [pscustomobject]@{
    name = $Name
    ok = ($code -eq 0)
    code = $code
    command = "powercfg $($Arguments -join ' ')"
    output = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
  }
  if ($code -ne 0 -and -not $AllowFailure) {
    throw "$($result.command) failed with code $code. $($result.output)"
  }
  $result
}

function Get-CoolingSettingIds {
  @{
    processor = '54533251-82be-4824-96c1-47b60b740d00'
    min = '893dee8e-2bef-41e0-89c6-b55d0929964c'
    max = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
    cooling = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'
    boost = 'be337238-0d82-4146-a960-4f3749d470c7'
    epp = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'
  }
}

function Set-CoolingValue {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Setting,
    [Parameter(Mandatory = $true)][int]$Value
  )

  $ids = Get-CoolingSettingIds
  Invoke-WinverPowercfg -Name $Name -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', $ids.processor, $Setting, [string]$Value) -AllowFailure
}

function Get-WinverThermalRows {
  $zones = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue
  @($zones | ForEach-Object {
    $celsius = [math]::Round(($_.CurrentTemperature / 10) - 273.15, 1)
    [pscustomobject]@{
      zone = $_.InstanceName
      celsius = $celsius
      valid = ($celsius -gt -50 -and $celsius -lt 130)
    }
  })
}

function Show-CoolingStatus {
  $ids = Get-CoolingSettingIds
  $temps = Get-WinverThermalRows
  $validTemps = @($temps | Where-Object { $_.valid })
  [pscustomobject]@{
    activePowerScheme = Invoke-Safe { (powercfg /getactivescheme) -join ' ' } ''
    maxCelsius = if ($validTemps.Count -gt 0) { [math]::Round(($validTemps | Measure-Object celsius -Maximum).Maximum, 1) } else { $null }
    thermalZones = $temps
    processorSettings = @(
      Invoke-WinverPowercfg -Name 'cooling policy' -Arguments @('/query', 'SCHEME_CURRENT', $ids.processor, $ids.cooling) -AllowFailure
      Invoke-WinverPowercfg -Name 'processor min' -Arguments @('/query', 'SCHEME_CURRENT', $ids.processor, $ids.min) -AllowFailure
      Invoke-WinverPowercfg -Name 'processor max' -Arguments @('/query', 'SCHEME_CURRENT', $ids.processor, $ids.max) -AllowFailure
      Invoke-WinverPowercfg -Name 'boost mode' -Arguments @('/query', 'SCHEME_CURRENT', $ids.processor, $ids.boost) -AllowFailure
      Invoke-WinverPowercfg -Name 'energy performance preference' -Arguments @('/query', 'SCHEME_CURRENT', $ids.processor, $ids.epp) -AllowFailure
    )
  } | ConvertTo-Json -Depth 6
}

function Show-CoolingPlan {
  $profile = $CoolingProfile
  if ($profile -eq 'status') {
    Show-CoolingStatus
    return
  }

  $plans = @{
    max = @(
      'activate high-performance power scheme when Windows exposes it',
      'prefer active cooling on AC',
      'set AC processor min/max to 100/100 percent',
      'set processor boost mode to aggressive where exposed',
      'set energy-performance preference to maximum performance where exposed',
      'disable plugged-in sleep and turn display off quickly'
    )
    cool = @(
      'use balanced power scheme',
      'prefer active cooling on AC',
      'set AC processor min/max to 5/85 percent',
      'disable boost where exposed',
      'keep plugged-in sleep disabled for server use',
      'reduce heat while staying remotely reachable'
    )
    balanced = @(
      'use balanced power scheme',
      'prefer active cooling on AC',
      'set AC processor min/max to 5/100 percent',
      'use efficient boost where exposed',
      'keep plugged-in sleep disabled for server use'
    )
    quiet = @(
      'use balanced power scheme',
      'prefer passive cooling on AC',
      'set AC processor min/max to 5/65 percent',
      'disable boost where exposed',
      'trade speed for less fan noise and lower heat'
    )
  }

  [pscustomobject]@{
    mode = $Mode
    profile = $profile
    directFanControl = 'Not exposed through a stable Surface Windows API; using Windows cooling policy and processor controls instead.'
    changes = $plans[$profile]
    rollback = 'Use winver admin rollback --apply or another cooling profile.'
  } | Format-List
}

function Apply-CoolingProfile {
  Assert-Admin
  if ($CoolingProfile -eq 'status') { throw "Use --dry-run for cooling status, or pass --profile max|cool|balanced|quiet with --apply." }

  $paths = New-WinverSnapshot -Reason "cooling-$CoolingProfile"
  $ids = Get-CoolingSettingIds
  $results = @()

  switch ($CoolingProfile) {
    'max' {
      $results += Invoke-WinverPowercfg -Name 'high performance scheme' -Arguments @('/setactive', 'SCHEME_MIN') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'disable AC standby' -Arguments @('/change', 'standby-timeout-ac', '0') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'disable AC hibernate timeout' -Arguments @('/change', 'hibernate-timeout-ac', '0') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'fast display timeout' -Arguments @('/change', 'monitor-timeout-ac', '1') -AllowFailure
      $results += Set-CoolingValue -Name 'active cooling' -Setting $ids.cooling -Value 1
      $results += Set-CoolingValue -Name 'processor min 100' -Setting $ids.min -Value 100
      $results += Set-CoolingValue -Name 'processor max 100' -Setting $ids.max -Value 100
      $results += Set-CoolingValue -Name 'boost aggressive' -Setting $ids.boost -Value 2
      $results += Set-CoolingValue -Name 'performance preference 0' -Setting $ids.epp -Value 0
    }
    'cool' {
      $results += Invoke-WinverPowercfg -Name 'balanced scheme' -Arguments @('/setactive', 'SCHEME_BALANCED') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'disable AC standby' -Arguments @('/change', 'standby-timeout-ac', '0') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'disable AC hibernate timeout' -Arguments @('/change', 'hibernate-timeout-ac', '0') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'short display timeout' -Arguments @('/change', 'monitor-timeout-ac', '5') -AllowFailure
      $results += Set-CoolingValue -Name 'active cooling' -Setting $ids.cooling -Value 1
      $results += Set-CoolingValue -Name 'processor min 5' -Setting $ids.min -Value 5
      $results += Set-CoolingValue -Name 'processor max 85' -Setting $ids.max -Value 85
      $results += Set-CoolingValue -Name 'boost disabled' -Setting $ids.boost -Value 0
      $results += Set-CoolingValue -Name 'performance preference 35' -Setting $ids.epp -Value 35
    }
    'balanced' {
      $results += Invoke-WinverPowercfg -Name 'balanced scheme' -Arguments @('/setactive', 'SCHEME_BALANCED') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'disable AC standby' -Arguments @('/change', 'standby-timeout-ac', '0') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'disable AC hibernate timeout' -Arguments @('/change', 'hibernate-timeout-ac', '0') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'normal display timeout' -Arguments @('/change', 'monitor-timeout-ac', '10') -AllowFailure
      $results += Set-CoolingValue -Name 'active cooling' -Setting $ids.cooling -Value 1
      $results += Set-CoolingValue -Name 'processor min 5' -Setting $ids.min -Value 5
      $results += Set-CoolingValue -Name 'processor max 100' -Setting $ids.max -Value 100
      $results += Set-CoolingValue -Name 'boost efficient' -Setting $ids.boost -Value 3
      $results += Set-CoolingValue -Name 'performance preference 50' -Setting $ids.epp -Value 50
    }
    'quiet' {
      $results += Invoke-WinverPowercfg -Name 'balanced scheme' -Arguments @('/setactive', 'SCHEME_BALANCED') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'AC standby 30 minutes' -Arguments @('/change', 'standby-timeout-ac', '30') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'disable AC hibernate timeout' -Arguments @('/change', 'hibernate-timeout-ac', '0') -AllowFailure
      $results += Invoke-WinverPowercfg -Name 'normal display timeout' -Arguments @('/change', 'monitor-timeout-ac', '10') -AllowFailure
      $results += Set-CoolingValue -Name 'passive cooling' -Setting $ids.cooling -Value 0
      $results += Set-CoolingValue -Name 'processor min 5' -Setting $ids.min -Value 5
      $results += Set-CoolingValue -Name 'processor max 65' -Setting $ids.max -Value 65
      $results += Set-CoolingValue -Name 'boost disabled' -Setting $ids.boost -Value 0
      $results += Set-CoolingValue -Name 'performance preference 80' -Setting $ids.epp -Value 80
    }
  }

  $results += Invoke-WinverPowercfg -Name 'refresh active scheme' -Arguments @('/setactive', 'SCHEME_CURRENT') -AllowFailure

  Write-Host "Cooling profile applied: $CoolingProfile" -ForegroundColor Green
  Write-Host "Snapshot: $($paths.snapshot)"
  Write-Host "Rollback: $($paths.rollback)"
  $results | Format-Table name, ok, code -AutoSize
  Write-Audit -Result "cooling-$CoolingProfile-applied" -Detail @{ snapshot = $paths.snapshot; rollback = $paths.rollback; results = $results }
}

function Apply-ServerProfile {
  Assert-Admin
  Assert-BitLockerPrepared
  $paths = New-WinverSnapshot -Reason 'server-profile'

  powercfg /change standby-timeout-ac 0 | Out-Null
  powercfg /change hibernate-timeout-ac 0 | Out-Null
  powercfg /change monitor-timeout-ac 5 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
  powercfg /setactive SCHEME_MIN | Out-Null

  Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service -Name sshd -ErrorAction SilentlyContinue
  Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service -Name Tailscale -ErrorAction SilentlyContinue

  $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  if (Test-Path $winlogon) {
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
  }

  $updateUx = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
  if (Test-Path $updateUx) {
    Set-ItemProperty -Path $updateUx -Name ActiveHoursStart -Value 8 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $updateUx -Name ActiveHoursEnd -Value 22 -Type DWord -ErrorAction SilentlyContinue
  }

  Write-Host "Server profile applied." -ForegroundColor Green
  Write-Host "Snapshot: $($paths.snapshot)"
  Write-Host "Rollback: $($paths.rollback)"
  Write-Audit -Result 'applied' -Detail $paths
}

function Apply-Lockdown {
  Assert-Admin
  Assert-BitLockerPrepared
  $paths = New-WinverSnapshot -Reason 'lockdown'

  powercfg /setactive SCHEME_MIN | Out-Null
  powercfg /change standby-timeout-ac 0 | Out-Null
  powercfg /change hibernate-timeout-ac 0 | Out-Null
  powercfg /change monitor-timeout-ac 1 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 60 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR SYSCOOLPOL 1 | Out-Null
  powercfg /setactive SCHEME_CURRENT | Out-Null

  Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service -Name sshd -ErrorAction SilentlyContinue
  Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service -Name Tailscale -ErrorAction SilentlyContinue

  $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  if (Test-Path $winlogon) {
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
  }

  $updateUx = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
  if (Test-Path $updateUx) {
    Set-ItemProperty -Path $updateUx -Name ActiveHoursStart -Value 7 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $updateUx -Name ActiveHoursEnd -Value 23 -Type DWord -ErrorAction SilentlyContinue
  }

  Write-Host "Lockdown mode applied. The Surface is now biased toward plugged-in server use." -ForegroundColor Green
  Write-Host "Snapshot: $($paths.snapshot)"
  Write-Host "Rollback: $($paths.rollback)"
  Write-Host "To make it friendly for direct use again: winver admin unlock --apply"
  Write-Audit -Result 'lockdown-applied' -Detail $paths
}

function Apply-Unlock {
  Assert-Admin
  $paths = New-WinverSnapshot -Reason 'unlock'

  powercfg /setactive SCHEME_BALANCED | Out-Null
  powercfg /change standby-timeout-ac 30 | Out-Null
  powercfg /change hibernate-timeout-ac 0 | Out-Null
  powercfg /change monitor-timeout-ac 10 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 1800 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 600 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
  powercfg /setactive SCHEME_CURRENT | Out-Null

  Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
  Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue

  Write-Host "Unlock mode applied. The Surface is back to a more normal plugged-in laptop profile." -ForegroundColor Green
  Write-Host "Snapshot: $($paths.snapshot)"
  Write-Host "Rollback: $($paths.rollback)"
  Write-Audit -Result 'unlock-applied' -Detail $paths
}

function Apply-Rollback {
  Assert-Admin
  $latest = Get-ChildItem -Path $snapshotRoot -Filter '*.rollback.ps1' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $latest) { throw "No rollback script found under $snapshotRoot." }
  Write-Host "Running rollback: $($latest.FullName)" -ForegroundColor Yellow
  & $latest.FullName
  Write-Audit -Result 'rollback' -Detail @{ rollback = $latest.FullName }
}

function Apply-ExportRecovery {
  Assert-Admin
  New-Item -ItemType Directory -Force -Path $recoveryRoot | Out-Null
  $paths = New-WinverSnapshot -Reason 'export-recovery'
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $output = Join-Path $recoveryRoot "$stamp-bitlocker.recovery.txt"
  manage-bde -protectors -get C: > $output
  icacls $output /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
  Write-Host "Recovery data exported locally: $output" -ForegroundColor Green
  Write-Host "Snapshot: $($paths.snapshot)"
  Write-Audit -Result 'exported-recovery' -Detail @{ output = $output; snapshot = $paths.snapshot }
}

function Apply-BreakGlass {
  Assert-Admin
  $paths = New-WinverSnapshot -Reason 'break-glass'
  Stop-Service sshd -ErrorAction SilentlyContinue
  Set-Service sshd -StartupType Disabled -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName 'WinverAutoUpdate' -Confirm:$false -ErrorAction SilentlyContinue
  Get-NetFirewallRule -Name 'Winver-SSHD-Tailscale' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
  Write-Host "Break-glass applied: sshd disabled, auto-update removed, winver SSH firewall rule disabled." -ForegroundColor Yellow
  Write-Host "Snapshot: $($paths.snapshot)"
  Write-Audit -Result 'break-glass' -Detail $paths
}

try {
  if (-not (Test-WinverAdminAction -Action $Action)) { throw "Unknown admin action '$Action'." }
  Assert-SignedApply

  if ($Mode -eq 'Apply' -and (Test-WinverDangerousAction -Action $Action)) {
    New-Item -ItemType Directory -Force -Path $programRoot, $auditRoot, $snapshotRoot | Out-Null
  }

  switch ($Action) {
    'status' { Show-Status }
    'power' { powercfg /getactivescheme; powercfg /query SCHEME_CURRENT SUB_SLEEP; Write-Audit -Result 'read-power' }
    'services' { Get-Service sshd, Tailscale, wuauserv, WinDefend -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize; Write-Audit -Result 'read-services' }
    'updates' { Get-Service wuauserv -ErrorAction SilentlyContinue | Format-List; Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10 | Format-Table -AutoSize; Write-Audit -Result 'read-updates' }
    'defender' { Invoke-Safe { Get-MpComputerStatus } '(Defender status unavailable)' | Format-List; Write-Audit -Result 'read-defender' }
    'firewall' { Get-NetFirewallRule -Name 'Winver-SSHD-Tailscale', 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Format-List; Write-Audit -Result 'read-firewall' }
    'bitlocker' { Invoke-Safe { Get-BitLockerVolume } '(BitLocker module unavailable)' | Format-List; Write-Audit -Result 'read-bitlocker' }
    'tpm' { Invoke-Safe { Get-Tpm } '(TPM unavailable)' | Format-List; Write-Host "SecureBoot: $(Invoke-Safe { Confirm-SecureBootUEFI } 'unavailable')"; Write-Audit -Result 'read-tpm' }
    'battery' { Invoke-Safe { Get-CimInstance Win32_Battery } '(battery unavailable)' | Format-List; Write-Audit -Result 'read-battery' }
    'thermal' { Invoke-Safe { Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature } '(thermal sensors unavailable)' | Format-List; Write-Audit -Result 'read-thermal' }
    'server-profile' { if ($Mode -eq 'Apply') { Apply-ServerProfile } else { Show-ServerProfilePlan; Write-Audit -Result 'dry-run-server-profile' } }
    'lockdown' { if ($Mode -eq 'Apply') { Apply-Lockdown } else { Show-LockdownPlan; Write-Audit -Result 'dry-run-lockdown' } }
    'cooling' { if ($Mode -eq 'Apply') { Apply-CoolingProfile } else { Show-CoolingPlan; Write-Audit -Result "dry-run-cooling-$CoolingProfile" } }
    'unlock' { if ($Mode -eq 'Apply') { Apply-Unlock } else { Show-UnlockPlan; Write-Audit -Result 'dry-run-unlock' } }
    'rollback' { if ($Mode -eq 'Apply') { Apply-Rollback } else { Get-ChildItem -Path $snapshotRoot -Filter '*.rollback.ps1' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5; Write-Audit -Result 'dry-run-rollback' } }
    'export-recovery' { if ($Mode -eq 'Apply') { Apply-ExportRecovery } else { Write-Host "Would export BitLocker recovery data to $recoveryRoot and lock it to Administrators/SYSTEM."; Write-Audit -Result 'dry-run-export-recovery' } }
    'break-glass' { if ($Mode -eq 'Apply') { Apply-BreakGlass } else { Write-Host "Would disable sshd, remove WinverAutoUpdate, and disable the winver SSH firewall rule."; Write-Audit -Result 'dry-run-break-glass' } }
    'reboot' { if ($Mode -eq 'Apply') { Assert-Admin; Assert-BitLockerPrepared; New-WinverSnapshot -Reason 'reboot' | Out-Null; Write-Audit -Result 'reboot'; Restart-Computer -Force } else { Write-Host "Would reboot this Surface."; Write-Audit -Result 'dry-run-reboot' } }
    'shutdown' { if ($Mode -eq 'Apply') { Assert-Admin; Assert-BitLockerPrepared; New-WinverSnapshot -Reason 'shutdown' | Out-Null; Write-Audit -Result 'shutdown'; Stop-Computer -Force } else { Write-Host "Would shut down this Surface."; Write-Audit -Result 'dry-run-shutdown' } }
    'admin-shell' {
      if ($Mode -ne 'Apply' -or -not $Force) { throw "admin-shell requires -Mode Apply and -Force." }
      if (-not $AdminShellCommand) { throw "admin-shell requires -AdminShellCommand." }
      Assert-Admin
      New-WinverSnapshot -Reason 'admin-shell' | Out-Null
      Write-Audit -Result 'admin-shell-start' -Detail @{ command = '[redacted in audit]' }
      Invoke-Expression $AdminShellCommand
      Write-Audit -Result 'admin-shell-complete'
    }
  }
} catch {
  Write-Audit -Result 'error' -Detail @{ message = $_.Exception.Message }
  throw
}
