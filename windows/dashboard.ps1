[CmdletBinding()]
param(
  [int]$RecentJobs = 12,
  [int]$SlowTtlSeconds = 10,
  [switch]$ForceRefresh,
  [string]$WinverHome = (Join-Path $env:USERPROFILE '.winver')
)

$ErrorActionPreference = 'Stop'

$LogRoot = Join-Path $WinverHome 'logs'
$DashboardRoot = Join-Path $WinverHome 'dashboard'
$SlowCachePath = Join-Path $DashboardRoot 'slow.json'
$LivePath = Join-Path $DashboardRoot 'live.json'
$SamplerPidPath = Join-Path $DashboardRoot 'sampler.pid'

function Invoke-Safe {
  param([scriptblock]$Script, $Fallback = $null)
  try { & $Script } catch { $Fallback }
}

function ConvertTo-Megabytes {
  param([double]$Bytes)
  [math]::Round($Bytes / 1MB, 1)
}

function ConvertTo-ArgumentList {
  param([string[]]$Values)
  @($Values | ForEach-Object {
    $text = [string]$_
    if ($text -match '[\s"]') { '"' + ($text -replace '"', '\"') + '"' } else { $text }
  })
}

function Get-AgeMilliseconds {
  param([string]$IsoDate)
  try {
    return [int](([DateTimeOffset]::Now - [DateTimeOffset]::Parse($IsoDate)).TotalMilliseconds)
  } catch {
    return $null
  }
}

function Get-LiveSnapshot {
  if (-not (Test-Path -LiteralPath $LivePath)) { return $null }
  $snapshot = Invoke-Safe { Get-Content -LiteralPath $LivePath -Raw | ConvertFrom-Json } $null
  if (-not $snapshot -or -not $snapshot.collectedAt) { return $null }
  $ageMs = Get-AgeMilliseconds -IsoDate ([string]$snapshot.collectedAt)
  if ($null -eq $ageMs -or $ageMs -gt 6000) { return $null }
  $snapshot | Add-Member -NotePropertyName ageMs -NotePropertyValue $ageMs -Force
  $snapshot
}

function Test-SamplerRunning {
  if (-not (Test-Path -LiteralPath $SamplerPidPath)) { return $false }
  $samplerPid = Invoke-Safe { [int](Get-Content -LiteralPath $SamplerPidPath -Raw) } 0
  if ($samplerPid -le 0) { return $false }
  [bool](Get-Process -Id $samplerPid -ErrorAction SilentlyContinue)
}

function Start-DashboardSampler {
  if (Test-SamplerRunning) { return $false }
  New-Item -ItemType Directory -Force -Path $DashboardRoot | Out-Null
  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $script = Join-Path $PSScriptRoot 'dashboard-sampler.ps1'
  $args = ConvertTo-ArgumentList @(
    '-NoLogo',
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $script,
    '-WinverHome',
    $WinverHome
  )
  Invoke-Safe { Start-Process -FilePath $powershell -ArgumentList $args -WindowStyle Hidden | Out-Null } | Out-Null
  $true
}

function Get-LiveSnapshotOrStartSampler {
  $live = Get-LiveSnapshot
  if ($live) {
    $live | Add-Member -NotePropertyName samplerStarted -NotePropertyValue $false -Force
    return $live
  }

  $started = Start-DashboardSampler
  for ($i = 0; $i -lt 8; $i += 1) {
    Start-Sleep -Milliseconds 250
    $live = Get-LiveSnapshot
    if ($live) {
      $live | Add-Member -NotePropertyName samplerStarted -NotePropertyValue $started -Force
      return $live
    }
  }
  $null
}

function Get-ValidTemperature {
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

function Get-WinverServices {
  @(Get-Service sshd, Tailscale -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{
      name = $_.Name
      status = [string]$_.Status
      startType = [string]$_.StartType
    }
  })
}

function Get-WinverProcesses {
  $names = @('powershell', 'pwsh', 'node', 'codex', 'python', 'python3')
  @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $names -contains $_.ProcessName.ToLowerInvariant() } |
    Sort-Object CPU -Descending |
    Select-Object -First 24 |
    ForEach-Object {
      [pscustomobject]@{
        name = $_.ProcessName
        id = $_.Id
        cpuSeconds = [math]::Round([double]($_.CPU), 1)
        memoryMB = ConvertTo-Megabytes $_.WorkingSet64
      }
    })
}

function Get-WinverJobs {
  if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) { return @() }
  $jobs = Get-ChildItem -LiteralPath $LogRoot -Directory | Sort-Object Name -Descending | Select-Object -First $RecentJobs
  @($jobs | ForEach-Object {
    $jobDir = $_.FullName
    $metaPath = Join-Path $jobDir 'meta.json'
    $exitPath = Join-Path $jobDir 'exit.code'
    $stdoutPath = Join-Path $jobDir 'stdout.log'
    $stderrPath = Join-Path $jobDir 'stderr.log'

    $meta = $null
    if (Test-Path -LiteralPath $metaPath) {
      $meta = Invoke-Safe { Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json } $null
    }

    $pidValue = if ($meta -and $meta.pid) { [int]$meta.pid } else { 0 }
    $running = if ($pidValue -gt 0) { [bool](Get-Process -Id $pidValue -ErrorAction SilentlyContinue) } else { $false }
    $exit = if (Test-Path -LiteralPath $exitPath) { (Get-Content -LiteralPath $exitPath -Raw).Trim() } else { 'pending' }
    $stdoutBytes = if (Test-Path -LiteralPath $stdoutPath) { (Get-Item -LiteralPath $stdoutPath).Length } else { 0 }
    $stderrBytes = if (Test-Path -LiteralPath $stderrPath) { (Get-Item -LiteralPath $stderrPath).Length } else { 0 }
    $lastOutput = if (Test-Path -LiteralPath $stdoutPath) {
      @(Get-Content -LiteralPath $stdoutPath -Tail 6 -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ })
    } else {
      @()
    }
    $command = if ($meta -and $meta.command) { [string]$meta.command } else { '' }
    $preview = ($command -replace '\s+', ' ').Trim()
    if ($preview.Length -gt 160) { $preview = $preview.Substring(0, 157) + '...' }

    [pscustomobject]@{
      id = $_.Name
      pid = $pidValue
      running = $running
      exit = $exit
      startedAt = if ($meta -and $meta.startedAt) { [string]$meta.startedAt } else { '' }
      commandPreview = $preview
      stdoutBytes = $stdoutBytes
      stderrBytes = $stderrBytes
      lastOutput = $lastOutput
    }
  })
}

function Get-CachedSlowSnapshot {
  if ($ForceRefresh -or $SlowTtlSeconds -le 0) { return $null }
  if (-not (Test-Path -LiteralPath $SlowCachePath)) { return $null }

  $file = Get-Item -LiteralPath $SlowCachePath -ErrorAction SilentlyContinue
  if (-not $file) { return $null }
  if (((Get-Date) - $file.LastWriteTime).TotalSeconds -gt $SlowTtlSeconds) { return $null }

  Invoke-Safe { Get-Content -LiteralPath $SlowCachePath -Raw | ConvertFrom-Json } $null
}

function Set-CachedSlowSnapshot {
  param($Snapshot)
  New-Item -ItemType Directory -Force -Path $DashboardRoot | Out-Null
  $Snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SlowCachePath -Encoding utf8
}

function Get-SlowSnapshot {
  $cached = Get-CachedSlowSnapshot
  if ($cached) { return $cached }

  $temps = Get-ValidTemperature
  $validTemps = @($temps | Where-Object { $_.valid })
  $snapshot = [pscustomobject]@{
    slowCollectedAt = (Get-Date).ToString('o')
    power = @{
      activeScheme = Invoke-Safe { (powercfg /getactivescheme) -join ' ' } ''
    }
    thermal = @{
      maxCelsius = if ($validTemps.Count -gt 0) { [math]::Round(($validTemps | Measure-Object celsius -Maximum).Maximum, 1) } else { $null }
      zones = $temps
    }
    services = Get-WinverServices
    processes = Get-WinverProcesses
    jobs = Get-WinverJobs
  }

  Invoke-Safe { Set-CachedSlowSnapshot -Snapshot $snapshot } | Out-Null
  $snapshot
}

$cpu = @(Get-CimInstance Win32_Processor | Select-Object -First 1)[0]
$os = Get-CimInstance Win32_OperatingSystem
$fallbackBattery = Invoke-Safe { Get-CimInstance Win32_Battery | Select-Object -First 1 } $null
$live = Get-LiveSnapshotOrStartSampler
$slow = Get-SlowSnapshot
$cpuLoadPercent = if ($live -and $live.cpu -and $null -ne $live.cpu.loadPercent) { [double]$live.cpu.loadPercent } else { [double]$cpu.LoadPercentage }
$memorySnapshot = if ($live -and $live.memory) {
  $live.memory
} else {
  @{
    totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
    freeMB = [math]::Round($os.FreePhysicalMemory / 1024, 0)
    usedPercent = [math]::Round((1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100, 1)
  }
}
$batterySnapshot = if ($live -and $live.battery) {
  $live.battery
} elseif ($fallbackBattery) {
  @{
    percent = [int]$fallbackBattery.EstimatedChargeRemaining
    status = [string]$fallbackBattery.BatteryStatus
  }
} else { $null }

[pscustomobject]@{
  collectedAt = (Get-Date).ToString('o')
  computer = @{
    name = $env:COMPUTERNAME
    user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    os = $os.Caption
    version = $os.Version
    uptimeSeconds = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
  }
  cpu = @{
    name = $cpu.Name
    loadPercent = [math]::Round($cpuLoadPercent, 1)
    source = if ($live -and $live.cpu -and $live.cpu.source) { [string]$live.cpu.source } else { 'cim-fallback' }
    sampleAgeMs = if ($live) { $live.ageMs } else { $null }
  }
  memory = $memorySnapshot
  battery = $batterySnapshot
  power = $slow.power
  thermal = $slow.thermal
  services = $slow.services
  processes = $slow.processes
  jobs = $slow.jobs
  dashboard = @{
    slowCollectedAt = $slow.slowCollectedAt
    slowTtlSeconds = $SlowTtlSeconds
    forceRefresh = [bool]$ForceRefresh
    sampler = @{
      running = Test-SamplerRunning
      started = if ($live) { [bool]$live.samplerStarted } else { $false }
      liveCollectedAt = if ($live) { [string]$live.collectedAt } else { '' }
      liveAgeMs = if ($live) { $live.ageMs } else { $null }
    }
  }
} | ConvertTo-Json -Depth 8
