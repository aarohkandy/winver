[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('main')]
  [string]$Branch = 'main',

  [Parameter(Position = 1)]
  [ValidateSet('light', 'medium', 'heavy')]
  [string]$Preset = 'medium',

  [Parameter(Position = 2)]
  [ValidateSet('train', 'preflight')]
  [string]$Mode = 'train',

  [Parameter(Position = 3)]
  [string]$DatasetDir = '',

  [Parameter(Position = 4)]
  [ValidateSet('require-cuda', 'allow-cpu')]
  [string]$Hardware = 'require-cuda',

  [Parameter(Position = 5)]
  [ValidateSet('auto', 'setup')]
  [string]$SetupMode = 'auto',

  [Parameter(Position = 6)]
  [int]$DebugLimit = 0,

  [switch]$No4Bit
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PreflightOnly = $Mode -eq 'preflight'
$AllowCpu = $Hardware -eq 'allow-cpu'
$Setup = $SetupMode -eq 'setup'

function Write-Step {
  param([string]$Message)
  Write-Output ""
  Write-Output "==> $Message"
}

function Require-File {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing required file: $Path"
  }
}

function Require-Directory {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Missing required directory: $Path"
  }
}

function Count-Jsonl {
  param([string]$Path)
  $count = 0
  Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object {
    if ($_.Trim().Length -gt 0) { $count += 1 }
  }
  return $count
}

if (-not $env:WINVER_DATA -or -not $env:WINVER_RUNS -or -not $env:WINVER_LOGS) {
  throw 'This script must run through `winver job start`, because it needs WINVER_DATA, WINVER_RUNS, and WINVER_LOGS.'
}

$ProjectRoot = Join-Path $env:WINVER_REPO 'projects\copaine-training'
$DefaultDatasetDir = Join-Path $env:WINVER_DATA 'copaine\training_assets_kaggle_human_plus_topical'
$DownloadsDatasetDir = 'C:\Users\arvin\Downloads\copaine\training_assets_kaggle_human_plus_topical'
if (-not $DatasetDir) {
  $DatasetDir = $DefaultDatasetDir
}

$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunRoot = Join-Path $env:WINVER_RUNS 'copaine'
$RunDir = Join-Path $RunRoot "$Preset-$RunStamp"

Write-Step 'Job context'
Write-Output "job=$env:WINVER_JOB_NAME"
Write-Output "repo=$env:WINVER_REPO"
Write-Output "data=$env:WINVER_DATA"
Write-Output "runs=$env:WINVER_RUNS"
Write-Output "logs=$env:WINVER_LOGS"
Write-Output "project_root=$ProjectRoot"
Write-Output "dataset_dir=$DatasetDir"
Write-Output "run_dir=$RunDir"
Write-Output "preset=$Preset"
Write-Output "mode=$Mode"
Write-Output "hardware=$Hardware"
Write-Output "setup_mode=$SetupMode"

Write-Step 'Use bundled Copaine training code'
Require-Directory $ProjectRoot
Push-Location $env:WINVER_REPO
try {
  git rev-parse HEAD
} finally {
  Pop-Location
}

Push-Location $ProjectRoot
try {
  $VenvPython = Join-Path $ProjectRoot '.venv-gemma\Scripts\python.exe'
  Require-File (Join-Path $ProjectRoot 'train_qwen_lora.py')
  Require-File (Join-Path $ProjectRoot 'model_presets.py')
  if (-not (Test-Path -LiteralPath $DatasetDir -PathType Container) -and
      $DatasetDir -eq $DefaultDatasetDir -and
      (Test-Path -LiteralPath $DownloadsDatasetDir -PathType Container)) {
    Write-Step 'Stage dataset into WINVER_DATA'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DatasetDir) | Out-Null
    Copy-Item -LiteralPath $DownloadsDatasetDir -Destination $DatasetDir -Recurse -Force
  }
  Require-Directory $DatasetDir

  $TrainFileName = 'train_mixed.jsonl'
  $ValFileName = 'val_mixed.jsonl'
  if (-not (Test-Path -LiteralPath (Join-Path $DatasetDir $TrainFileName) -PathType Leaf) -and
      (Test-Path -LiteralPath (Join-Path $DatasetDir 'train_chat.jsonl') -PathType Leaf)) {
    $TrainFileName = 'train_chat.jsonl'
    $ValFileName = 'val_chat.jsonl'
  }

  $TrainFile = Join-Path $DatasetDir $TrainFileName
  $ValFile = Join-Path $DatasetDir $ValFileName
  Require-File $TrainFile
  Require-File $ValFile

  $TrainCount = Count-Jsonl $TrainFile
  $ValCount = Count-Jsonl $ValFile
  if ($TrainCount -lt 10) {
    throw "Training set looks too small: $TrainCount rows in $TrainFile"
  }
  if ($ValCount -lt 1) {
    throw "Validation set is empty: $ValFile"
  }

  Write-Step 'Dataset check'
  Write-Output "train_file=$TrainFileName"
  Write-Output "val_file=$ValFileName"
  Write-Output "train_rows=$TrainCount"
  Write-Output "val_rows=$ValCount"
  Get-ChildItem -LiteralPath $DatasetDir -File | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize

  Write-Step 'Windows GPU check'
  $VideoControllers = @(Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name)
  $VideoControllers | ForEach-Object { Write-Output "video_controller=$_" }
  $HasNvidiaGpu = $VideoControllers | Where-Object { $_ -match 'NVIDIA' }
  if (-not $HasNvidiaGpu -and -not $AllowCpu) {
    throw 'No NVIDIA/CUDA GPU was detected. Refusing to start a long CPU training run. Use a CUDA-capable Windows box or pass allow-cpu deliberately.'
  }

  if ($Setup -or -not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
    Write-Step 'Install or refresh Python training environment'
    $setupArgs = @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ProjectRoot 'setup_local_gemma.ps1'), '-TorchBackend', 'cu121')
    powershell.exe @setupArgs
  }

  Require-File $VenvPython

  Write-Step 'Python dependency and CUDA check'
  $CudaJson = & $VenvPython -c @'
import json
import importlib.util

missing = [name for name in ["torch", "datasets", "peft", "transformers", "trl"] if importlib.util.find_spec(name) is None]
payload = {"missing": missing}
if not missing:
    import torch
    payload.update({
        "torch": torch.__version__,
        "cuda_available": torch.cuda.is_available(),
        "cuda_device_count": torch.cuda.device_count(),
        "cuda_name": torch.cuda.get_device_name(0) if torch.cuda.is_available() else "",
        "cuda_version": torch.version.cuda,
        "bf16_supported": bool(torch.cuda.is_available() and torch.cuda.is_bf16_supported()),
    })
print(json.dumps(payload))
'@
  Write-Output $CudaJson
  $Cuda = $CudaJson | ConvertFrom-Json
  if ($Cuda.missing.Count -gt 0) {
    throw "Missing Python training packages in .venv-gemma: $($Cuda.missing -join ', '). Rerun with -Setup."
  }
  if (-not $Cuda.cuda_available -and -not $AllowCpu) {
    throw 'CUDA is not available. Refusing to start a long CPU training run. Use a CUDA-capable Windows box or pass -AllowCpu deliberately.'
  }

  Write-Step 'Model preset'
  $PresetJson = & $VenvPython -c "import json; from model_presets import get_preset; print(json.dumps(get_preset('$Preset').to_public_dict()))"
  Write-Output $PresetJson
  $PresetData = $PresetJson | ConvertFrom-Json

  if ($PreflightOnly) {
    Write-Step 'Preflight complete'
    Write-Output 'Preflight passed. Training was not started because -PreflightOnly was set.'
    exit 0
  }

  New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

  Write-Step 'Start training'
  $TrainArgs = @(
    '-X', 'utf8',
    (Join-Path $ProjectRoot 'train_qwen_lora.py'),
    '--preset', $Preset,
    '--dataset-dir', $DatasetDir,
    '--train-file', $TrainFileName,
    '--val-file', $ValFileName,
    '--output-dir', $RunDir,
    '--report-to', 'tensorboard'
  )

  if ($AllowCpu) { $TrainArgs += '--allow-cpu' }
  if ($No4Bit) { $TrainArgs += '--no-4bit' }
  if ($DebugLimit -gt 0) {
    $TrainArgs += '--debug-limit'
    $TrainArgs += "$DebugLimit"
  }

  Write-Output "command=$VenvPython $($TrainArgs -join ' ')"
  & $VenvPython @TrainArgs
  $exitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } else { 0 }
  if ($exitCode -ne 0) { exit $exitCode }

  Write-Step 'Training complete'
  Write-Output "run_dir=$RunDir"
} finally {
  Pop-Location
}
