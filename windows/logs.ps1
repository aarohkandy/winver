[CmdletBinding()]
param(
  [string]$Target = 'latest',
  [string]$LogRoot = (Join-Path $env:USERPROFILE '.winver\logs'),
  [int]$Tail = 160
)

if (-not (Test-Path $LogRoot)) {
  Write-Output "No winver logs yet: $LogRoot"
  exit 0
}

$jobs = Get-ChildItem -Path $LogRoot -Directory | Sort-Object Name -Descending
if (-not $jobs) {
  Write-Output "No winver jobs yet."
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

Write-Output ""
Write-Output $job.Name
if (Test-Path $meta) { Get-Content $meta }
if (Test-Path $exitCode) { Write-Output "exit: $(Get-Content $exitCode)" }

Write-Output ""
Write-Output "stdout"
if (Test-Path $stdout) { Get-Content $stdout -Tail $Tail } else { Write-Output "(empty)" }

Write-Output ""
Write-Output "stderr"
if (Test-Path $stderr) { Get-Content $stderr -Tail $Tail } else { Write-Output "(empty)" }
