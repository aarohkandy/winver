[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Branch = 'main',

  [Parameter(Position = 1)]
  [ValidateSet('preflight', 'smoke')]
  [string]$Mode = 'smoke',

  [Parameter(Position = 2)]
  [ValidateSet('auto', 'setup')]
  [string]$SetupMode = 'auto',

  [Parameter(Position = 3)]
  [ValidateSet('require-cuda', 'allow-cpu')]
  [string]$Hardware = 'allow-cpu',

  [string]$RepoUrl = 'git@github.com:aarohkandy/diffusion-for-cad.git'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Setup = $SetupMode -eq 'setup'
$AllowCpu = $Hardware -eq 'allow-cpu'

function Write-Step {
  param([string]$Message)
  Write-Output ''
  Write-Output "==> $Message"
}

function Require-File {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing required file: $Path"
  }
}

function Invoke-Checked {
  param(
    [string]$Label,
    [string]$Exe,
    [string[]]$Arguments
  )
  Write-Step $Label
  Write-Output "command=$Exe $($Arguments -join ' ')"
  & $Exe @Arguments
  $exitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } else { 0 }
  if ($exitCode -ne 0) { exit $exitCode }
}

if (-not $env:WINVER_DATA -or -not $env:WINVER_RUNS -or -not $env:WINVER_LOGS) {
  throw 'This script must run through `winver job start`, because it needs WINVER_DATA, WINVER_RUNS, and WINVER_LOGS.'
}

$ProjectRoot = Join-Path $env:WINVER_DATA 'projects\diffusion-for-cad'
$DeployKey = Join-Path $env:USERPROFILE '.ssh\diffusion_for_cad_deploy_ed25519'
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunRoot = Join-Path $env:WINVER_RUNS 'diffusion-for-cad'
$RunDir = Join-Path $RunRoot "$Mode-$RunStamp"
$DataRoot = Join-Path $RunDir 'data'
$NativeRunsRoot = Join-Path $RunDir 'native-runs'
$ConfigDir = Join-Path $RunDir 'configs'

$env:CAD_NATIVE_DATA_ROOT = $DataRoot
$env:CAD_NATIVE_RUNS_ROOT = $NativeRunsRoot

Write-Step 'Job context'
Write-Output "job=$env:WINVER_JOB_NAME"
Write-Output "data=$env:WINVER_DATA"
Write-Output "runs=$env:WINVER_RUNS"
Write-Output "project_root=$ProjectRoot"
Write-Output "repo_url=$RepoUrl"
Write-Output "run_dir=$RunDir"
Write-Output "branch=$Branch"
Write-Output "mode=$Mode"
Write-Output "setup_mode=$SetupMode"
Write-Output "hardware=$Hardware"

Write-Step 'Clone or update diffusion-for-cad repo'
Require-File $DeployKey
$env:GIT_SSH_COMMAND = "ssh -i `"$DeployKey`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ProjectRoot) | Out-Null
  git clone $RepoUrl $ProjectRoot
}

Push-Location $ProjectRoot
try {
  git fetch origin
  git checkout $Branch
  git pull --ff-only origin $Branch
  git rev-parse HEAD

  $VenvPython = Join-Path $ProjectRoot '.venv-cad\Scripts\python.exe'
  $TrainingRequirements = Join-Path $ProjectRoot 'training\requirements.txt'
  Require-File $TrainingRequirements

  if ($Setup -or -not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
    Write-Step 'Install or refresh CAD training environment'
    $PythonLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($PythonLauncher) {
      & $PythonLauncher.Source -3 -m venv (Join-Path $ProjectRoot '.venv-cad')
      if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } else {
      $PythonCommand = Get-Command python -ErrorAction SilentlyContinue
      if (-not $PythonCommand) { throw 'Python was not found on this Windows machine.' }
      & $PythonCommand.Source -m venv (Join-Path $ProjectRoot '.venv-cad')
      if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Require-File $VenvPython
    & $VenvPython -m pip install --upgrade pip setuptools wheel
    if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & $VenvPython -m pip install -r $TrainingRequirements
    if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }

  Require-File $VenvPython
  New-Item -ItemType Directory -Force -Path $RunDir, $DataRoot, $NativeRunsRoot, $ConfigDir | Out-Null

  Write-Step 'Python and hardware check'
  $HardwareCheck = Join-Path $ConfigDir 'hardware_check.py'
  Set-Content -LiteralPath $HardwareCheck -Encoding UTF8 -Value @'
import json
import importlib.util

missing = [name for name in ["torch", "numpy", "yaml"] if importlib.util.find_spec(name) is None]
payload = {"missing": missing}
if not missing:
    import torch
    payload.update({
        "python_ok": True,
        "torch": torch.__version__,
        "cuda_available": torch.cuda.is_available(),
        "cuda_device_count": torch.cuda.device_count(),
        "cuda_name": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
        "mps_available": bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available()),
    })
print(json.dumps(payload))
'@
  $HardwareJson = & $VenvPython $HardwareCheck
  if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Output $HardwareJson
  $HardwareInfo = $HardwareJson | ConvertFrom-Json
  if ($HardwareInfo.missing.Count -gt 0) {
    throw "Missing Python packages in .venv-cad: $($HardwareInfo.missing -join ', '). Rerun with setup."
  }
  if (-not $HardwareInfo.cuda_available -and -not $AllowCpu) {
    throw 'CUDA is not available. Use allow-cpu for this smoke run or move to a CUDA Windows box.'
  }

  $AutoencoderConfig = Join-Path $ConfigDir 'autoencoder_surface.yaml'
  Set-Content -LiteralPath $AutoencoderConfig -Encoding UTF8 -Value @'
processed_dir: ${CAD_NATIVE_DATA_ROOT}/processed/train
max_faces: 16
max_edges: 32
latent_dim: 64
hidden_dim: 256
batch_size: 8
epochs: 8
lr: 0.001
seed: 7
device: auto
'@

  $DiffusionConfig = Join-Path $ConfigDir 'diffusion_category_surface.yaml'
  Set-Content -LiteralPath $DiffusionConfig -Encoding UTF8 -Value @'
processed_dir: ${CAD_NATIVE_DATA_ROOT}/processed/train
autoencoder_checkpoint: ${CAD_NATIVE_RUNS_ROOT}/autoencoder/latest_checkpoint.txt
hidden_dim: 256
time_dim: 64
category_dim: 32
category_conditioning: true
batch_size: 8
epochs: 8
lr: 0.001
diffusion_steps: 100
seed: 13
device: auto
'@

  Invoke-Checked 'Prepare synthetic CAD-native samples' $VenvPython @(
    '-m', 'training.cad_native.cli.data',
    'prepare',
    '--source', 'synthetic',
    '--limit', '32'
  )

  Invoke-Checked 'Validate processed samples' $VenvPython @(
    '-m', 'training.cad_native.cli.data',
    'validate',
    '--dir', (Join-Path $DataRoot 'processed\train')
  )

  if ($Mode -eq 'preflight') {
    Write-Step 'Preflight complete'
    Write-Output "run_dir=$RunDir"
    exit 0
  }

  Invoke-Checked 'Train B-rep autoencoder' $VenvPython @(
    '-m', 'training.cad_native.cli.train',
    'autoencoder',
    '--config', $AutoencoderConfig
  )

  Invoke-Checked 'Train category-conditioned latent diffusion' $VenvPython @(
    '-m', 'training.cad_native.cli.train',
    'diffusion',
    '--config', $DiffusionConfig
  )

  $GenerateDir = Join-Path $RunDir 'generated_bracket'
  Invoke-Checked 'Generate bracket samples' $VenvPython @(
    '-m', 'training.cad_native.cli.generate',
    '--category', 'bracket',
    '--samples', '4',
    '--sample-steps', '16',
    '--out', $GenerateDir
  )

  Invoke-Checked 'Evaluate generated samples' $VenvPython @(
    '-m', 'training.cad_native.cli.eval',
    '--run', $GenerateDir
  )

  Write-Step 'CAD-native Surface smoke training complete'
  Write-Output "run_dir=$RunDir"
  Write-Output "generated_dir=$GenerateDir"
} finally {
  Pop-Location
}
