[CmdletBinding()]
param(
  [ValidateSet('stop-process', 'stop-job')]
  [string]$Action,

  [int]$ProcessId = 0,
  [string]$Target = '',
  [string]$WinverHome = (Join-Path $env:USERPROFILE '.winver')
)

$ErrorActionPreference = 'Stop'
$AllowedProcessNames = @('powershell', 'pwsh', 'node', 'codex', 'python', 'python3')
$LogRoot = Join-Path $WinverHome 'logs'

function Assert-SafeJobTarget {
  param([string]$Value)
  if ($Value -eq 'latest') { return }
  if ($Value -notmatch '^[0-9]{8}-[0-9]{6}-[A-Za-z0-9_.-]{1,80}$') {
    throw 'Unsafe job target.'
  }
}

function Get-JobDirectory {
  param([string]$JobTarget)
  Assert-SafeJobTarget $JobTarget
  if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
    throw "No winver logs yet: $LogRoot"
  }

  $jobs = Get-ChildItem -LiteralPath $LogRoot -Directory | Sort-Object Name -Descending
  if (-not $jobs) { throw 'No winver jobs yet.' }

  if ($JobTarget -eq 'latest') { return ($jobs | Select-Object -First 1).FullName }
  $job = $jobs | Where-Object { $_.Name -eq $JobTarget } | Select-Object -First 1
  if (-not $job) { throw "No job found for '$JobTarget'." }
  $job.FullName
}

function Stop-AllowedProcess {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { throw 'A positive process id is required.' }

  $process = Get-Process -Id $ProcessId -ErrorAction Stop
  $name = $process.ProcessName.ToLowerInvariant()
  if ($AllowedProcessNames -notcontains $name) {
    throw "Refusing to stop '$($process.ProcessName)'. Dashboard stop is limited to worker processes."
  }

  Stop-Process -Id $ProcessId -Force -ErrorAction Stop
  [pscustomobject]@{
    ok = $true
    action = 'stop-process'
    pid = $ProcessId
    name = $process.ProcessName
  } | ConvertTo-Json -Depth 3
}

function Stop-ProcessTree {
  param([int]$RootProcessId)
  $stopped = New-Object System.Collections.Generic.List[int]
  $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$RootProcessId" -ErrorAction SilentlyContinue)
  foreach ($child in $children) {
    Stop-ProcessTree -RootProcessId ([int]$child.ProcessId) | ForEach-Object { $stopped.Add([int]$_) }
  }
  $process = Get-Process -Id $RootProcessId -ErrorAction SilentlyContinue
  if ($process) {
    Stop-Process -Id $RootProcessId -Force -ErrorAction Stop
    $stopped.Add($RootProcessId)
  }
  $stopped
}

function Stop-JobProcess {
  param([string]$JobTarget)
  $jobDir = Get-JobDirectory $JobTarget
  $metaPath = Join-Path $jobDir 'meta.json'
  if (-not (Test-Path -LiteralPath $metaPath)) { throw "Job has no metadata: $jobDir" }

  $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
  $processId = if ($meta.pid) { [int]$meta.pid } else { 0 }
  if ($processId -le 0) { throw 'Job has no process id.' }

  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if (-not $process) {
    [pscustomobject]@{
      ok = $true
      action = 'stop-job'
      id = (Split-Path -Leaf $jobDir)
      pid = $processId
      stopped = $false
      message = 'Process is already gone.'
    } | ConvertTo-Json -Depth 3
    return
  }

  $stoppedIds = @(Stop-ProcessTree -RootProcessId $processId)
  [pscustomobject]@{
    ok = $true
    action = 'stop-job'
    id = (Split-Path -Leaf $jobDir)
    pid = $processId
    stopped = $true
    stoppedPids = $stoppedIds
  } | ConvertTo-Json -Depth 3
}

switch ($Action) {
  'stop-process' { Stop-AllowedProcess -ProcessId $ProcessId }
  'stop-job' { Stop-JobProcess -JobTarget $Target }
}
