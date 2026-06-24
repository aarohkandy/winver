[CmdletBinding()]
param(
  [ValidateSet('list', 'start', 'logs', 'paths', 'status', 'archive')]
  [string]$Action = 'list',

  [string]$Name = '',
  [string]$Target = 'latest',
  [ValidateSet('logs', 'runs', 'data')]
  [string]$Kind = 'logs',
  [string]$ArgsJsonBase64 = '',
  [string]$RepoPath = (Join-Path $env:USERPROFILE 'winver'),
  [string]$WinverHome = (Join-Path $env:USERPROFILE '.winver'),
  [int]$Tail = 160,
  [switch]$SkipPull,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$JobsRoot = Join-Path $RepoPath 'jobs'
$LogRoot = Join-Path $WinverHome 'logs'
$DataRoot = Join-Path $WinverHome 'data'
$RunsRoot = Join-Path $WinverHome 'runs'
$TransferRoot = Join-Path $WinverHome 'transfer'
$EnvFile = Join-Path $WinverHome 'env.ps1'

function Assert-WinverJobName {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') {
    throw 'Job names may use only letters, numbers, hyphens, and underscores, and must start with a letter or number.'
  }
}

function ConvertTo-PowerShellSingleQuoted {
  param([AllowNull()][string]$Value)
  "'" + ([string]$Value).Replace("'", "''") + "'"
}

function ConvertTo-PowerShellArrayLiteral {
  param([string[]]$Values)
  if (-not $Values -or $Values.Count -eq 0) { return '@()' }
  $quoted = @($Values | ForEach-Object { ConvertTo-PowerShellSingleQuoted $_ })
  '@(' + ($quoted -join ', ') + ')'
}

function Initialize-WinverJobFolders {
  New-Item -ItemType Directory -Force -Path $LogRoot, $DataRoot, $RunsRoot, $TransferRoot | Out-Null
}

function Assert-WinverRelativePath {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw 'A target folder is required.'
  }
  if ([IO.Path]::IsPathRooted($Value) -or $Value -match ':' -or $Value -match '[*?<>|]') {
    throw 'Target must be a relative folder below the selected winver storage root.'
  }
  $segments = @($Value -replace '/', '\' -split '\\' | Where-Object { $_ })
  foreach ($segment in $segments) {
    if ($segment -eq '.' -or $segment -eq '..' -or $segment -notmatch '^[A-Za-z0-9][A-Za-z0-9._ -]{0,127}$') {
      throw 'Target contains an unsafe path segment.'
    }
  }
}

function Get-WinverJobArgs {
  if ([string]::IsNullOrWhiteSpace($ArgsJsonBase64)) { return @() }
  try {
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgsJsonBase64))
    $parsed = $json | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    return @($parsed | ForEach-Object { [string]$_ })
  } catch {
    throw 'Could not decode job arguments.'
  }
}

function Get-WinverJobScript {
  param([string]$JobName)
  Assert-WinverJobName $JobName
  if (-not (Test-Path -LiteralPath $JobsRoot -PathType Container)) {
    throw "No jobs folder found at $JobsRoot"
  }

  $scriptPath = Join-Path $JobsRoot "$JobName.ps1"
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "No job named '$JobName'. Try: winver job list"
  }

  $root = (Resolve-Path -LiteralPath $JobsRoot).Path.TrimEnd('\')
  $script = (Resolve-Path -LiteralPath $scriptPath).Path
  if (-not $script.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Resolved job path escaped the jobs folder."
  }
  $script
}

function Update-WinverRepo {
  if ($SkipPull) { return }
  Push-Location $RepoPath
  try {
    git pull --ff-only
  } finally {
    Pop-Location
  }
}

function Show-WinverJobList {
  if (-not (Test-Path -LiteralPath $JobsRoot -PathType Container)) {
    Write-Output "No jobs folder found at $JobsRoot"
    return
  }

  $jobs = Get-ChildItem -LiteralPath $JobsRoot -Filter '*.ps1' -File |
    Where-Object { $_.BaseName -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' } |
    Sort-Object BaseName

  if (-not $jobs) {
    Write-Output 'No jobs found.'
    return
  }

  $jobs | ForEach-Object { $_.BaseName }
}

function Show-WinverJobPaths {
  Initialize-WinverJobFolders
  Write-Output "repo=$RepoPath"
  Write-Output "jobs=$JobsRoot"
  Write-Output "data=$DataRoot"
  Write-Output "runs=$RunsRoot"
  Write-Output "logs=$LogRoot"
  Write-Output "transfer=$TransferRoot"
  Write-Output "env=$EnvFile"
}

function Get-WinverLogJobDirectory {
  param([string]$JobTarget)
  if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
    throw "No winver logs yet: $LogRoot"
  }

  $jobs = Get-ChildItem -LiteralPath $LogRoot -Directory | Sort-Object Name -Descending
  if (-not $jobs) { throw 'No winver jobs yet.' }

  if ($JobTarget -eq 'latest') {
    return ($jobs | Select-Object -First 1).FullName
  }

  $job = $jobs | Where-Object { $_.Name -eq $JobTarget } | Select-Object -First 1
  if (-not $job) { throw "No job found for '$JobTarget'. Try: winver job logs list" }
  $job.FullName
}

function Show-WinverJobStatus {
  Initialize-WinverJobFolders
  $jobDir = Get-WinverLogJobDirectory $Target
  $metaPath = Join-Path $jobDir 'meta.json'
  $exitPath = Join-Path $jobDir 'exit.code'
  $stdoutPath = Join-Path $jobDir 'stdout.log'
  $stderrPath = Join-Path $jobDir 'stderr.log'

  $meta = $null
  if (Test-Path -LiteralPath $metaPath) {
    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
  }

  $pidValue = if ($meta -and $meta.pid) { [int]$meta.pid } else { 0 }
  $running = $false
  if ($pidValue -gt 0) {
    $running = [bool](Get-Process -Id $pidValue -ErrorAction SilentlyContinue)
  }

  $exit = if (Test-Path -LiteralPath $exitPath) { (Get-Content -LiteralPath $exitPath -Raw).Trim() } else { 'pending' }
  $stdoutBytes = if (Test-Path -LiteralPath $stdoutPath) { (Get-Item -LiteralPath $stdoutPath).Length } else { 0 }
  $stderrBytes = if (Test-Path -LiteralPath $stderrPath) { (Get-Item -LiteralPath $stderrPath).Length } else { 0 }

  Write-Output "id=$((Split-Path -Leaf $jobDir))"
  Write-Output "pid=$pidValue"
  Write-Output "running=$running"
  Write-Output "exit=$exit"
  Write-Output "stdoutBytes=$stdoutBytes"
  Write-Output "stderrBytes=$stderrBytes"
  if ($meta -and $meta.startedAt) { Write-Output "startedAt=$($meta.startedAt)" }
}

function Resolve-WinverPullSource {
  Initialize-WinverJobFolders
  switch ($Kind) {
    'logs' {
      return Get-WinverLogJobDirectory $Target
    }
    'runs' {
      Assert-WinverRelativePath $Target
      $path = Join-Path $RunsRoot ($Target -replace '/', '\')
      if (-not (Test-Path -LiteralPath $path)) { throw "No runs path found: $path" }
      return (Resolve-Path -LiteralPath $path).Path
    }
    'data' {
      Assert-WinverRelativePath $Target
      $path = Join-Path $DataRoot ($Target -replace '/', '\')
      if (-not (Test-Path -LiteralPath $path)) { throw "No data path found: $path" }
      return (Resolve-Path -LiteralPath $path).Path
    }
  }
}

function New-WinverArchive {
  Initialize-WinverJobFolders
  $source = Resolve-WinverPullSource
  $leaf = Split-Path -Leaf $source
  $safeTarget = (($Target -replace '[^A-Za-z0-9_. -]', '-') -replace '\s+', '-').Trim('-')
  if (-not $safeTarget) { $safeTarget = $leaf }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $name = "winver-$Kind-$safeTarget-$stamp.zip"
  $archive = Join-Path $TransferRoot $name
  if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }

  Compress-Archive -LiteralPath $source -DestinationPath $archive -Force
  Write-Output "kind=$Kind"
  Write-Output "target=$Target"
  Write-Output "source=$source"
  Write-Output "archive=$archive"
  Write-Output "name=$name"
}

function Start-WinverNamedJob {
  Initialize-WinverJobFolders
  Update-WinverRepo

  $jobScript = Get-WinverJobScript $Name
  $jobArgs = Get-WinverJobArgs
  $jobArgsLiteral = ConvertTo-PowerShellArrayLiteral $jobArgs

  $command = @"
`$ErrorActionPreference = 'Stop'
`$env:WINVER_REPO = $(ConvertTo-PowerShellSingleQuoted $RepoPath)
`$env:WINVER_DATA = $(ConvertTo-PowerShellSingleQuoted $DataRoot)
`$env:WINVER_RUNS = $(ConvertTo-PowerShellSingleQuoted $RunsRoot)
`$env:WINVER_LOGS = $(ConvertTo-PowerShellSingleQuoted $LogRoot)
`$env:WINVER_JOB_NAME = $(ConvertTo-PowerShellSingleQuoted $Name)
New-Item -ItemType Directory -Force -Path `$env:WINVER_DATA, `$env:WINVER_RUNS, `$env:WINVER_LOGS | Out-Null
if (Test-Path -LiteralPath $(ConvertTo-PowerShellSingleQuoted $EnvFile)) { . $(ConvertTo-PowerShellSingleQuoted $EnvFile) }
`$WinverJobArgs = $jobArgsLiteral
& $(ConvertTo-PowerShellSingleQuoted $jobScript) @WinverJobArgs
"@

  if ($DryRun) {
    Write-Output "job=$Name"
    Write-Output "script=$jobScript"
    Write-Output "args=$($jobArgs -join ' ')"
    Write-Output "data=$DataRoot"
    Write-Output "runs=$RunsRoot"
    return
  }

  & (Join-Path $RepoPath 'windows\run-job.ps1') -Command $command -Name $Name -RepoPath $RepoPath -LogRoot $LogRoot
}

switch ($Action) {
  'list' {
    Show-WinverJobList
  }
  'start' {
    Start-WinverNamedJob
  }
  'logs' {
    Initialize-WinverJobFolders
    & (Join-Path $RepoPath 'windows\logs.ps1') -Target $Target -LogRoot $LogRoot -Tail $Tail
  }
  'paths' {
    Show-WinverJobPaths
  }
  'status' {
    Show-WinverJobStatus
  }
  'archive' {
    New-WinverArchive
  }
}
