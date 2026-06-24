[CmdletBinding()]
param(
  [int]$RecentJobs = 12,
  [string]$WinverHome = (Join-Path $env:USERPROFILE '.winver')
)

$ErrorActionPreference = 'Stop'

$LogRoot = Join-Path $WinverHome 'logs'

function Invoke-Safe {
  param([scriptblock]$Script, $Fallback = $null)
  try { & $Script } catch { $Fallback }
}

function ConvertTo-Megabytes {
  param([double]$Bytes)
  [math]::Round($Bytes / 1MB, 1)
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
    Select-Object -First 12 |
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

$os = Get-CimInstance Win32_OperatingSystem
$cpu = @(Get-CimInstance Win32_Processor | Select-Object -First 1)[0]
$temps = Get-ValidTemperature
$validTemps = @($temps | Where-Object { $_.valid })
$battery = Invoke-Safe { Get-CimInstance Win32_Battery | Select-Object -First 1 } $null
$powerScheme = Invoke-Safe { (powercfg /getactivescheme) -join ' ' } ''

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
    loadPercent = [int]($cpu.LoadPercentage)
  }
  memory = @{
    totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
    freeMB = [math]::Round($os.FreePhysicalMemory / 1024, 0)
    usedPercent = [math]::Round((1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100, 1)
  }
  battery = if ($battery) {
    @{
      percent = [int]$battery.EstimatedChargeRemaining
      status = [string]$battery.BatteryStatus
    }
  } else { $null }
  power = @{
    activeScheme = $powerScheme
  }
  thermal = @{
    maxCelsius = if ($validTemps.Count -gt 0) { [math]::Round(($validTemps | Measure-Object celsius -Maximum).Maximum, 1) } else { $null }
    zones = $temps
  }
  services = Get-WinverServices
  processes = Get-WinverProcesses
  jobs = Get-WinverJobs
} | ConvertTo-Json -Depth 8
