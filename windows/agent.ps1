[CmdletBinding()]
param(
  [switch]$Install,
  [switch]$Uninstall,
  [string]$RepoPath = (Join-Path $env:USERPROFILE 'winver'),
  [string]$TaskName = 'WinverAutoUpdate'
)

$ErrorActionPreference = 'Stop'
$logRoot = Join-Path $env:USERPROFILE '.winver\logs'
$agentLog = Join-Path $logRoot 'agent.log'

function Write-AgentLog {
  param([string]$Message)
  New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
  Add-Content -Path $agentLog -Value ("{0} {1}" -f (Get-Date).ToString('o'), $Message)
}

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Removed $TaskName if it existed."
  exit 0
}

if ($Install) {
  $scriptPath = Join-Path $RepoPath 'windows\agent.ps1'
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -RepoPath `"$RepoPath`""
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
  $trigger.Repetition.Interval = 'PT15M'
  $trigger.Repetition.Duration = 'P3650D'
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Pull latest winver helper code.' -Force | Out-Null
  Write-Host "Installed $TaskName."
  exit 0
}

try {
  if (-not (Test-Path $RepoPath)) { throw "Repo path missing: $RepoPath" }
  Push-Location $RepoPath
  $before = git rev-parse --short HEAD
  git pull --ff-only | Tee-Object -Variable pullOutput | Out-Null
  $after = git rev-parse --short HEAD
  Write-AgentLog "pull $before -> $after :: $($pullOutput -join ' ')"
} catch {
  Write-AgentLog "error: $($_.Exception.Message)"
  throw
} finally {
  Pop-Location -ErrorAction SilentlyContinue
}
