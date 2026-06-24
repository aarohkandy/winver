[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Command,

  [string]$Name = 'job',
  [string]$RepoPath = (Join-Path $env:USERPROFILE 'winver'),
  [string]$LogRoot = (Join-Path $env:USERPROFILE '.winver\logs')
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeName = ($Name -replace '[^A-Za-z0-9_.-]', '-').Trim('-')
if (-not $safeName) { $safeName = 'job' }
$jobId = "$stamp-$safeName"
$jobDir = Join-Path $LogRoot $jobId
$stdout = Join-Path $jobDir 'stdout.log'
$stderr = Join-Path $jobDir 'stderr.log'
$runner = Join-Path $jobDir 'run.ps1'
$cmdRunner = Join-Path $jobDir 'run.cmd'
$meta = Join-Path $jobDir 'meta.json'

New-Item -ItemType Directory -Force -Path $jobDir | Out-Null

$script = @"
`$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath '$($RepoPath.Replace("'", "''"))'
`$command = @'
$Command
'@
Invoke-Expression `$command
if (`$LASTEXITCODE -is [int]) { exit `$LASTEXITCODE }
exit 0
"@

Set-Content -Path $runner -Value $script -Encoding utf8

function ConvertTo-CmdQuoted {
  param([Parameter(Mandatory = $true)][string]$Value)
  '"' + ($Value -replace '"', '""') + '"'
}

$cmdScript = @"
@echo off
powershell.exe -NonInteractive -NoLogo -NoProfile -ExecutionPolicy Bypass -File $(ConvertTo-CmdQuoted $runner) > $(ConvertTo-CmdQuoted $stdout) 2> $(ConvertTo-CmdQuoted $stderr)
set WINVER_EXIT=%ERRORLEVEL%
> $(ConvertTo-CmdQuoted (Join-Path $jobDir 'exit.code')) echo %WINVER_EXIT%
exit /b %WINVER_EXIT%
"@

Set-Content -Path $cmdRunner -Value $cmdScript -Encoding ascii

$process = Start-Process `
  -FilePath 'cmd.exe' `
  -ArgumentList "/d /c $(ConvertTo-CmdQuoted $cmdRunner)" `
  -WindowStyle Hidden `
  -PassThru

[pscustomobject]@{
  id = $jobId
  pid = $process.Id
  command = $Command
  startedAt = (Get-Date).ToString('o')
  repoPath = $RepoPath
  stdout = $stdout
  stderr = $stderr
} | ConvertTo-Json -Depth 4 | Set-Content -Path $meta -Encoding utf8

Write-Output "Started $jobId (pid $($process.Id))"
Write-Output "Logs: $jobDir"
