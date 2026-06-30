[CmdletBinding()]
param(
  [int]$IntervalMilliseconds = 1000,
  [string]$WinverHome = (Join-Path $env:USERPROFILE '.winver')
)

$ErrorActionPreference = 'SilentlyContinue'

$DashboardRoot = Join-Path $WinverHome 'dashboard'
$LivePath = Join-Path $DashboardRoot 'live.json'
$TempPath = Join-Path $DashboardRoot 'live.tmp'
$PidPath = Join-Path $DashboardRoot 'sampler.pid'

New-Item -ItemType Directory -Force -Path $DashboardRoot | Out-Null
Set-Content -LiteralPath $PidPath -Value $PID -Encoding ascii

function New-CpuCounter {
  try {
    $counter = [System.Diagnostics.PerformanceCounter]::new('Processor', '% Processor Time', '_Total')
    $null = $counter.NextValue()
    return $counter
  } catch {
    return $null
  }
}

function Get-CpuSnapshot {
  param($Counter)
  $cpuValues = @(Get-CimInstance Win32_Processor |
    Where-Object { $null -ne $_.LoadPercentage } |
    ForEach-Object { [double]$_.LoadPercentage })
  if ($cpuValues.Count -gt 0) {
    return @{
      loadPercent = [math]::Round(($cpuValues | Measure-Object -Average).Average, 1)
      source = 'cim-sampler'
    }
  }

  if ($Counter) {
    $value = [double]$Counter.NextValue()
    if (-not [double]::IsNaN($value)) {
      return @{
        loadPercent = [math]::Round([math]::Min([math]::Max($value, 0), 100), 1)
        source = 'performance-counter-fallback'
      }
    }
  }

  return @{
    loadPercent = $null
    source = 'unavailable'
  }
}

function Get-MemorySnapshot {
  $os = Get-CimInstance Win32_OperatingSystem
  if (-not $os) { return $null }
  [pscustomobject]@{
    totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
    freeMB = [math]::Round($os.FreePhysicalMemory / 1024, 0)
    usedPercent = [math]::Round((1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100, 1)
  }
}

function Get-BatterySnapshot {
  $battery = Get-CimInstance Win32_Battery | Select-Object -First 1
  if (-not $battery) { return $null }
  [pscustomobject]@{
    percent = [int]$battery.EstimatedChargeRemaining
    status = [string]$battery.BatteryStatus
  }
}

function Get-SmoothedCpuLoad {
  param([double[]]$Samples)
  $valid = @($Samples | Where-Object { $null -ne $_ } | Sort-Object)
  if ($valid.Count -eq 0) { return $null }
  $middle = [math]::Floor($valid.Count / 2)
  if ($valid.Count % 2 -eq 1) { return [math]::Round([double]$valid[$middle], 1) }
  [math]::Round((([double]$valid[$middle - 1] + [double]$valid[$middle]) / 2), 1)
}

$cpuCounter = New-CpuCounter
$cpuSamples = New-Object System.Collections.Generic.List[double]
Start-Sleep -Milliseconds ([math]::Max($IntervalMilliseconds, 250))

while ($true) {
  $cpuSnapshot = Get-CpuSnapshot -Counter $cpuCounter
  if ($null -ne $cpuSnapshot.loadPercent) {
    $cpuSamples.Add([double]$cpuSnapshot.loadPercent)
    while ($cpuSamples.Count -gt 7) { $cpuSamples.RemoveAt(0) }
  }
  $smoothedCpu = Get-SmoothedCpuLoad -Samples ([double[]]$cpuSamples.ToArray())
  $snapshot = [pscustomobject]@{
    collectedAt = (Get-Date).ToString('o')
    pid = $PID
    cpu = @{
      loadPercent = if ($null -ne $smoothedCpu) { $smoothedCpu } else { $cpuSnapshot.loadPercent }
      instantPercent = $cpuSnapshot.loadPercent
      source = $cpuSnapshot.source
      smoothing = 'median-7'
    }
    memory = Get-MemorySnapshot
    battery = Get-BatterySnapshot
  }

  $snapshot | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TempPath -Encoding utf8
  Move-Item -LiteralPath $TempPath -Destination $LivePath -Force
  Start-Sleep -Milliseconds ([math]::Max($IntervalMilliseconds, 250))
}
