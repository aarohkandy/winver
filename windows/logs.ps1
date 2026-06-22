[CmdletBinding()]
param(
  [string]$Target = 'latest',
  [string]$LogRoot = (Join-Path $env:USERPROFILE '.winver\logs'),
  [int]$Tail = 160
)

if (-not (Test-Path $LogRoot)) {
  Write-Host "No winver logs yet: $LogRoot"
  exit 0
}

$jobs = Get-ChildItem -Path $LogRoot -Directory | Sort-Object Name -Descending
if (-not $jobs) {
  Write-Host "No winver jobs yet."
  exit 0
}

if ($Target -eq 'list') {
  $jobs | Select-Object -First 20 | ForEach-Object {
    $meta = Join-Path $_.FullName 'meta.json'
    if (Test-Path $meta) {
      $data = Get-Content $meta -Raw | ConvertFrom-Json
      "{0}  pid={1}  {2}" -f $data.id, $data.pid, $data.command
    } else {
      $_.Name
    }
  }
  exit 0
}

$job = if ($Target -eq 'latest') {
  $jobs | Select-Object -First 1
} else {
  $jobs | Where-Object { $_.Name -eq $Target } | Select-Object -First 1
}

if (-not $job) {
  throw "No job found for '$Target'. Try: winver logs list"
}

$meta = Join-Path $job.FullName 'meta.json'
$stdout = Join-Path $job.FullName 'stdout.log'
$stderr = Join-Path $job.FullName 'stderr.log'
$exitCode = Join-Path $job.FullName 'exit.code'

Write-Host ""
Write-Host $job.Name -ForegroundColor Cyan
if (Test-Path $meta) { Get-Content $meta }
if (Test-Path $exitCode) { Write-Host "exit: $(Get-Content $exitCode)" -ForegroundColor Yellow }

Write-Host ""
Write-Host "stdout" -ForegroundColor Green
if (Test-Path $stdout) { Get-Content $stdout -Tail $Tail } else { Write-Host "(empty)" }

Write-Host ""
Write-Host "stderr" -ForegroundColor Yellow
if (Test-Path $stderr) { Get-Content $stderr -Tail $Tail } else { Write-Host "(empty)" }

