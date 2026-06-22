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
$meta = Join-Path $jobDir 'meta.json'

New-Item -ItemType Directory -Force -Path $jobDir | Out-Null

$script = @"
`$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath '$($RepoPath.Replace("'", "''"))'
`$command = @'
$Command
'@
Invoke-Expression `$command
`$exit = if (`$LASTEXITCODE -is [int]) { `$LASTEXITCODE } else { 0 }
Set-Content -Path '$($jobDir.Replace("'", "''"))\exit.code' -Value `$exit
exit `$exit
"@

Set-Content -Path $runner -Value $script -Encoding utf8

$process = Start-Process `
  -FilePath 'powershell.exe' `
  -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) `
  -RedirectStandardOutput $stdout `
  -RedirectStandardError $stderr `
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

Write-Host "Started $jobId (pid $($process.Id))"
Write-Host "Logs: $jobDir"

