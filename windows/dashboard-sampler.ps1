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
$ProcessorCount = [math]::Max([Environment]::ProcessorCount, 1)

New-Item -ItemType Directory -Force -Path $DashboardRoot | Out-Null
Set-Content -LiteralPath $PidPath -Value $PID -Encoding ascii

function Get-TotalProcessCpuSeconds {
  $total = 0.0
  foreach ($process in [System.Diagnostics.Process]::GetProcesses()) {
    try {
      $total += $process.TotalProcessorTime.TotalSeconds
    } catch {
      # Processes can exit while being sampled.
    } finally {
      try { $process.Dispose() } catch {}
    }
  }
  $total
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

$cpuSamples = New-Object System.Collections.Generic.List[double]
$lastCpuSeconds = Get-TotalProcessCpuSeconds
$lastSampleAt = Get-Date
$lastMemory = Get-MemorySnapshot
$lastBattery = Get-BatterySnapshot
$tick = 0

Start-Sleep -Milliseconds ([math]::Max($IntervalMilliseconds, 250))

while ($true) {
  $now = Get-Date
  $currentCpuSeconds = Get-TotalProcessCpuSeconds
  $elapsedSeconds = [math]::Max(($now - $lastSampleAt).TotalSeconds, 0.001)
  $instantCpu = (($currentCpuSeconds - $lastCpuSeconds) / ($elapsedSeconds * $ProcessorCount)) * 100
  $instantCpu = [math]::Round([math]::Min([math]::Max($instantCpu, 0), 100), 1)

  $lastCpuSeconds = $currentCpuSeconds
  $lastSampleAt = $now
  $cpuSamples.Add([double]$instantCpu)
  while ($cpuSamples.Count -gt 7) { $cpuSamples.RemoveAt(0) }
  $smoothedCpu = Get-SmoothedCpuLoad -Samples ([double[]]$cpuSamples.ToArray())

  if ($tick % 5 -eq 0 -or -not $lastMemory) { $lastMemory = Get-MemorySnapshot }
  if ($tick % 30 -eq 0) { $lastBattery = Get-BatterySnapshot }
  $tick += 1

  $snapshot = [pscustomobject]@{
    collectedAt = (Get-Date).ToString('o')
    pid = $PID
    cpu = @{
      loadPercent = if ($null -ne $smoothedCpu) { $smoothedCpu } else { $instantCpu }
      instantPercent = $instantCpu
      source = 'process-delta'
      smoothing = 'median-7'
    }
    memory = $lastMemory
    battery = $lastBattery
  }

  $snapshot | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TempPath -Encoding utf8
  Move-Item -LiteralPath $TempPath -Destination $LivePath -Force
  Start-Sleep -Milliseconds ([math]::Max($IntervalMilliseconds, 250))
}
