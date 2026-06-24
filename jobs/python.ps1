[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArgs
)

$ErrorActionPreference = 'Stop'

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue }
if (-not $python) {
  throw 'Python was not found on this Windows machine. Install Python or add it to PATH, then retry this job.'
}

& $python.Source @RemainingArgs
if ($LASTEXITCODE -is [int]) { exit $LASTEXITCODE }
