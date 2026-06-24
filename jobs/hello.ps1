[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArgs
)

$ErrorActionPreference = 'Stop'

Write-Output 'hello from winver job'
Write-Output "job=$env:WINVER_JOB_NAME"
Write-Output "repo=$env:WINVER_REPO"
Write-Output "data=$env:WINVER_DATA"
Write-Output "runs=$env:WINVER_RUNS"
if ($RemainingArgs.Count -gt 0) {
  Write-Output "args=$($RemainingArgs -join ' ')"
}

