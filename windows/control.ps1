[CmdletBinding()]
param(
  [ValidateSet('status', 'server-mode', 'balanced', 'reboot', 'shutdown', 'services', 'thermal')]
  [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'

function Get-Thermal {
  $zones = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue
  if (-not $zones) {
    Write-Host "Thermal sensors not exposed by Windows on this device."
    return
  }
  $zones | ForEach-Object {
    $celsius = [math]::Round(($_.CurrentTemperature / 10) - 273.15, 1)
    [pscustomobject]@{
      zone = $_.InstanceName
      celsius = $celsius
    }
  } | Format-Table -AutoSize
}

function Show-Status {
  Write-Host ""
  Write-Host "winver Surface status" -ForegroundColor Cyan
  Write-Host "====================="
  Get-ComputerInfo | Select-Object CsName, WindowsProductName, OsVersion, CsProcessors, CsTotalPhysicalMemory | Format-List
  Get-Service sshd, Tailscale -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize
  Write-Host ""
  powercfg /getactivescheme
  Write-Host ""
  Get-Process powershell, pwsh, node, codex -ErrorAction SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 12 Name, Id, CPU, WorkingSet | Format-Table -AutoSize
  Write-Host ""
  Get-Thermal
}

switch ($Action) {
  'status' {
    Show-Status
  }
  'services' {
    Get-Service sshd, Tailscale -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize
  }
  'thermal' {
    Get-Thermal
  }
  'server-mode' {
    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change hibernate-timeout-ac 0 | Out-Null
    powercfg /change monitor-timeout-ac 10 | Out-Null
    powercfg /setactive SCHEME_MIN | Out-Null
    Write-Host "Server mode enabled: plugged-in sleep disabled, display timeout kept short, high performance active." -ForegroundColor Green
  }
  'balanced' {
    powercfg /setactive SCHEME_BALANCED | Out-Null
    powercfg /change standby-timeout-ac 30 | Out-Null
    powercfg /change monitor-timeout-ac 10 | Out-Null
    Write-Host "Balanced mode restored." -ForegroundColor Green
  }
  'reboot' {
    Restart-Computer -Force
  }
  'shutdown' {
    Stop-Computer -Force
  }
}

