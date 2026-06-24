[CmdletBinding()]
param(
  [ValidateSet('list', 'start', 'logs', 'paths')]
  [string]$Action = 'list',

  [string]$Name = '',
  [string]$Target = 'latest',
  [string]$ArgsJsonBase64 = '',
  [string]$RepoPath = (Join-Path $env:USERPROFILE 'winver'),
  [string]$WinverHome = (Join-Path $env:USERPROFILE '.winver'),
  [switch]$SkipPull,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$JobsRoot = Join-Path $RepoPath 'jobs'
$LogRoot = Join-Path $WinverHome 'logs'
$DataRoot = Join-Path $WinverHome 'data'
$RunsRoot = Join-Path $WinverHome 'runs'
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
  New-Item -ItemType Directory -Force -Path $LogRoot, $DataRoot, $RunsRoot | Out-Null
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
  Write-Output "env=$EnvFile"
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
    & (Join-Path $RepoPath 'windows\logs.ps1') -Target $Target -LogRoot $LogRoot
  }
  'paths' {
    Show-WinverJobPaths
  }
}
