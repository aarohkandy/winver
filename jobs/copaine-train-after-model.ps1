[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('empathy')]
  [string]$Preset = 'empathy',

  [Parameter(Position = 1)]
  [int]$DebugLimit = 4,

  [Parameter(Position = 2)]
  [int]$TimeoutMinutes = 180
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $env:WINVER_DATA -or -not $env:WINVER_RUNS -or -not $env:WINVER_LOGS) {
  throw 'This script must run through `winver job start`, because it needs WINVER_DATA, WINVER_RUNS, and WINVER_LOGS.'
}

function Write-Step {
  param([string]$Message)
  Write-Output ""
  Write-Output "==> $Message"
}

$ModelDir = Join-Path $env:WINVER_DATA 'copaine\models\empathetic-qwen3-8b-Jan'
$RequiredFiles = @(
  'config.json',
  'tokenizer_config.json',
  'tokenizer.json',
  'model.safetensors.index.json',
  'model-00001-of-00004.safetensors',
  'model-00002-of-00004.safetensors',
  'model-00003-of-00004.safetensors',
  'model-00004-of-00004.safetensors'
)

Write-Step 'Wait for staged Copaine empathy model'
Write-Output "model_dir=$ModelDir"
Write-Output "timeout_minutes=$TimeoutMinutes"
Write-Output "debug_limit=$DebugLimit"

$Started = Get-Date
while ($true) {
  $Missing = @($RequiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ModelDir $_) -PathType Leaf) })
  $Parts = @()
  if (Test-Path -LiteralPath $ModelDir -PathType Container) {
    $Parts = @(Get-ChildItem -LiteralPath $ModelDir -Filter '*.part' -File -ErrorAction SilentlyContinue)
  }

  if ($Missing.Count -eq 0 -and $Parts.Count -eq 0) {
    break
  }

  $Elapsed = [math]::Round(((Get-Date) - $Started).TotalMinutes, 1)
  if ($Elapsed -gt $TimeoutMinutes) {
    throw "Timed out waiting for staged model after $Elapsed minutes. Missing=$($Missing -join ', ') parts=$($Parts.Name -join ', ')"
  }

  Write-Output "wait_elapsed_minutes=$Elapsed missing=$($Missing -join ',') parts=$($Parts.Name -join ',')"
  Start-Sleep -Seconds 60
}

Write-Step 'Model is staged; start smoke training'
$TrainScript = Join-Path $PSScriptRoot 'copaine-train.ps1'
& $TrainScript 'main' $Preset 'train' '' 'allow-cpu' 'auto' $DebugLimit 'no4bit' $ModelDir
exit $LASTEXITCODE
