param(
    [ValidateSet("cpu", "cu121", "cu124", "cu128")]
    [string]$TorchBackend = "cpu",
    [string]$VenvDir = ".venv-gemma"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $VenvDir)) {
    python -m venv $VenvDir
}

$python = Join-Path $VenvDir "Scripts\python.exe"

& $python -m pip install --upgrade pip setuptools wheel

if ($TorchBackend -eq "cpu") {
    & $python -m pip install torch torchvision torchaudio
} else {
    & $python -m pip install torch torchvision torchaudio --index-url "https://download.pytorch.org/whl/$TorchBackend"
}

& $python -m pip install -r requirements-gemma-local.txt

if ($TorchBackend -ne "cpu") {
    try {
        & $python -m pip install bitsandbytes
    } catch {
        Write-Warning "bitsandbytes install failed. You can still train without 4-bit quantization by using --no-4bit."
    }
}

Write-Host ""
Write-Host "Setup complete."
Write-Host "Activate with: $VenvDir\\Scripts\\Activate.ps1"
Write-Host "Next steps:"
Write-Host "  1. python audit_privacy_candidates.py"
Write-Host "  2. python prepare_support_bot_data.py"
Write-Host "  3. python prepare_training_assets.py"
Write-Host "  4. python -X utf8 train_gemma_local.py"
