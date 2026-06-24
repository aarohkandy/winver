[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Branch = 'main',

  [Parameter(Position = 1)]
  [ValidateSet('preflight', 'smoke', 'download-fusion', 'cook')]
  [string]$Mode = 'smoke',

  [Parameter(Position = 2)]
  [ValidateSet('auto', 'setup')]
  [string]$SetupMode = 'auto',

  [Parameter(Position = 3)]
  [ValidateSet('require-cuda', 'allow-cpu')]
  [string]$Hardware = 'allow-cpu',

  [Parameter(Position = 4)]
  [int]$Limit = 5000,

  [Parameter(Position = 5)]
  [int]$Epochs = 120,

  [Parameter(Position = 6)]
  [int]$ScanLimit = 0,

  [string]$RepoUrl = 'git@github.com:aarohkandy/diffusion-for-cad.git'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Setup = $SetupMode -eq 'setup'
$AllowCpu = $Hardware -eq 'allow-cpu'
$RealMode = $Mode -in @('download-fusion', 'cook')

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

function Download-IfMissing {
  param(
    [string]$Url,
    [string]$Path
  )
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    Write-Output "download_exists=$Path"
    return
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  $Partial = "$Path.part"
  if (Test-Path -LiteralPath $Partial) {
    Remove-Item -LiteralPath $Partial -Force
  }
  Write-Output "download_url=$Url"
  Write-Output "download_to=$Path"
  & curl.exe -L --fail --retry 5 --retry-delay 5 -o $Partial $Url
  if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Move-Item -LiteralPath $Partial -Destination $Path -Force
}

function Expand-Zip-IfNeeded {
  param(
    [string]$ZipPath,
    [string]$Destination
  )
  $Marker = Join-Path $Destination '.extracted'
  if (Test-Path -LiteralPath $Marker -PathType Leaf) {
    Write-Output "extract_exists=$Destination"
    return
  }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Write-Output "extract_zip=$ZipPath"
  Write-Output "extract_to=$Destination"
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
  Set-Content -LiteralPath $Marker -Encoding UTF8 -Value (Get-Date -Format o)
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
$DatasetRoot = Join-Path $env:WINVER_DATA 'datasets\diffusion-for-cad'
$DownloadRoot = Join-Path $DatasetRoot 'downloads'
$FusionUrl = 'https://fusion-360-gallery-dataset.s3.us-west-2.amazonaws.com/segmentation/s2.0.1/s2.0.1_extended_step.zip'
$FusionZip = Join-Path $DownloadRoot 's2.0.1_extended_step.zip'
$FusionRawRoot = Join-Path $DatasetRoot 'fusion\s2.0.1_extended_step'

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
Write-Output "real_data=$RealMode"
Write-Output "sample_limit=$Limit"
Write-Output "epochs=$Epochs"
Write-Output "scan_limit=$ScanLimit"

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
  $BaseRequirements = Join-Path $ProjectRoot 'training\requirements.txt'
  $RealRequirements = Join-Path $ProjectRoot 'training\requirements-real.txt'
  Require-File $BaseRequirements
  if ($RealMode) {
    Require-File $RealRequirements
  }

  if ($Setup -or -not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
    Write-Step 'Create or refresh CAD training environment'
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
    & $VenvPython -m pip install -r $BaseRequirements
    if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }

  Require-File $VenvPython
  if ($RealMode) {
    Invoke-Checked 'Install real STEP conversion dependencies' $VenvPython @(
      '-m', 'pip',
      'install',
      '-r', $RealRequirements
    )
  }

  New-Item -ItemType Directory -Force -Path $RunDir, $DataRoot, $NativeRunsRoot, $ConfigDir | Out-Null

  Write-Step 'Python and hardware check'
  $RequiredModules = if ($RealMode) { @('torch', 'numpy', 'yaml', 'cadquery') } else { @('torch', 'numpy', 'yaml') }
  $RequiredModulesLiteral = '[' + (($RequiredModules | ForEach-Object { "'$_'" }) -join ', ') + ']'
  $HardwareCheck = Join-Path $ConfigDir 'hardware_check.py'
  Set-Content -LiteralPath $HardwareCheck -Encoding UTF8 -Value @"
import json
import importlib.util

required = $RequiredModulesLiteral
missing = [name for name in required if importlib.util.find_spec(name) is None]
payload = {"missing": missing, "required": required}
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
"@
  $HardwareJson = & $VenvPython $HardwareCheck
  if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Output $HardwareJson
  $HardwareInfo = $HardwareJson | ConvertFrom-Json
  if ($HardwareInfo.missing.Count -gt 0) {
    throw "Missing Python packages in .venv-cad: $($HardwareInfo.missing -join ', '). Rerun with setup."
  }
  if (-not $HardwareInfo.cuda_available -and -not $AllowCpu) {
    throw 'CUDA is not available. Use allow-cpu for CPU training or move to a CUDA Windows box.'
  }

  if ($RealMode) {
    Write-Step 'Download Fusion 360 Gallery extended STEP data'
    Download-IfMissing $FusionUrl $FusionZip
    Expand-Zip-IfNeeded $FusionZip $FusionRawRoot
    if ($Mode -eq 'download-fusion') {
      Invoke-Checked 'Register Fusion STEP files' $VenvPython @(
        '-m', 'training.cad_native.cli.data',
        'prepare',
        '--source', 'fusion',
        '--input-root', $FusionRawRoot,
        '--out', (Join-Path $DataRoot 'processed\train'),
        '--scan-limit', [string]$ScanLimit,
        '--manifest-only'
      )
      Write-Step 'Fusion download/register complete'
      Write-Output "fusion_raw_root=$FusionRawRoot"
      Write-Output "run_dir=$RunDir"
      exit 0
    }
  }

  if ($Mode -in @('preflight', 'smoke')) {
    $AutoencoderConfig = Join-Path $ConfigDir 'autoencoder_surface_smoke.yaml'
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

    $DiffusionConfig = Join-Path $ConfigDir 'diffusion_surface_smoke.yaml'
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

    Invoke-Checked 'Prepare synthetic CAD-native smoke samples' $VenvPython @(
      '-m', 'training.cad_native.cli.data',
      'prepare',
      '--source', 'synthetic',
      '--limit', '32'
    )

    Invoke-Checked 'Validate processed smoke samples' $VenvPython @(
      '-m', 'training.cad_native.cli.data',
      'validate',
      '--dir', (Join-Path $DataRoot 'processed\train')
    )

    if ($Mode -eq 'preflight') {
      Write-Step 'Preflight complete'
      Write-Output "run_dir=$RunDir"
      exit 0
    }

    Invoke-Checked 'Train smoke B-rep autoencoder' $VenvPython @(
      '-m', 'training.cad_native.cli.train',
      'autoencoder',
      '--config', $AutoencoderConfig
    )

    Invoke-Checked 'Train smoke category-conditioned latent diffusion' $VenvPython @(
      '-m', 'training.cad_native.cli.train',
      'diffusion',
      '--config', $DiffusionConfig
    )

    $GenerateDir = Join-Path $RunDir 'generated_smoke_bracket'
    Invoke-Checked 'Generate smoke bracket samples' $VenvPython @(
      '-m', 'training.cad_native.cli.generate',
      '--category', 'bracket',
      '--samples', '4',
      '--sample-steps', '16',
      '--out', $GenerateDir
    )

    Invoke-Checked 'Evaluate smoke generated samples' $VenvPython @(
      '-m', 'training.cad_native.cli.eval',
      '--run', $GenerateDir
    )

    Write-Step 'CAD-native Surface smoke training complete'
    Write-Output "run_dir=$RunDir"
    Write-Output "generated_dir=$GenerateDir"
    exit 0
  }

  $AutoencoderConfig = Join-Path $ConfigDir 'autoencoder_fusion_real.yaml'
  $AutoencoderYaml = @'
processed_dir: ${CAD_NATIVE_DATA_ROOT}/processed/train
max_faces: 32
max_edges: 96
latent_dim: 256
hidden_dim: 1024
batch_size: 32
epochs: __EPOCHS__
lr: 0.0005
seed: 7
device: auto
'@
  $AutoencoderYaml = $AutoencoderYaml.Replace('__EPOCHS__', [string]$Epochs)
  Set-Content -LiteralPath $AutoencoderConfig -Encoding UTF8 -Value $AutoencoderYaml

  $DiffusionConfig = Join-Path $ConfigDir 'diffusion_fusion_real.yaml'
  $DiffusionYaml = @'
processed_dir: ${CAD_NATIVE_DATA_ROOT}/processed/train
autoencoder_checkpoint: ${CAD_NATIVE_RUNS_ROOT}/autoencoder/latest_checkpoint.txt
hidden_dim: 1024
time_dim: 128
category_dim: 64
category_conditioning: false
batch_size: 32
epochs: __EPOCHS__
lr: 0.0005
diffusion_steps: 300
seed: 13
device: auto
'@
  $DiffusionYaml = $DiffusionYaml.Replace('__EPOCHS__', [string]$Epochs)
  Set-Content -LiteralPath $DiffusionConfig -Encoding UTF8 -Value $DiffusionYaml

  Invoke-Checked 'Convert real Fusion STEP solids to CAD-native graph samples' $VenvPython @(
    '-m', 'training.cad_native.cli.data',
    'prepare',
    '--source', 'fusion',
    '--input-root', $FusionRawRoot,
    '--out', (Join-Path $DataRoot 'processed\train'),
    '--limit', [string]$Limit,
    '--scan-limit', [string]$ScanLimit,
    '--max-faces', '32',
    '--max-edges', '96',
    '--category', 'mechanical'
  )

  Invoke-Checked 'Validate real processed samples' $VenvPython @(
    '-m', 'training.cad_native.cli.data',
    'validate',
    '--dir', (Join-Path $DataRoot 'processed\train')
  )

  Invoke-Checked 'Train real Fusion B-rep autoencoder' $VenvPython @(
    '-m', 'training.cad_native.cli.train',
    'autoencoder',
    '--config', $AutoencoderConfig
  )

  Invoke-Checked 'Train real Fusion unconditional latent diffusion' $VenvPython @(
    '-m', 'training.cad_native.cli.train',
    'diffusion',
    '--config', $DiffusionConfig
  )

  $GenerateDir = Join-Path $RunDir 'generated_real_unconditional'
  Invoke-Checked 'Generate real-model unconditional samples' $VenvPython @(
    '-m', 'training.cad_native.cli.generate',
    '--samples', '16',
    '--sample-steps', '64',
    '--out', $GenerateDir
  )

  Invoke-Checked 'Evaluate generated real-model samples' $VenvPython @(
    '-m', 'training.cad_native.cli.eval',
    '--run', $GenerateDir
  )

  Write-Step 'CAD-native real Fusion training complete'
  Write-Output "run_dir=$RunDir"
  Write-Output "generated_dir=$GenerateDir"
  Write-Output "fusion_raw_root=$FusionRawRoot"
} finally {
  Pop-Location
}
