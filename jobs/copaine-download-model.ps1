[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('empathy')]
  [string]$Model = 'empathy'
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

function Invoke-CurlDownload {
  param(
    [string]$Url,
    [string]$OutputPath
  )

  $PartialPath = "$OutputPath.part"
  Write-Output "url=$Url"
  Write-Output "out=$OutputPath"
  & curl.exe `
    --http1.1 `
    -L `
    --fail `
    --retry 8 `
    --retry-all-errors `
    --retry-delay 5 `
    --connect-timeout 30 `
    --speed-time 120 `
    --speed-limit 1024 `
    -C - `
    -o $PartialPath `
    $Url
  if ($LASTEXITCODE -ne 0) {
    throw "curl failed with exit code $LASTEXITCODE for $Url"
  }
  Move-Item -LiteralPath $PartialPath -Destination $OutputPath -Force
  $item = Get-Item -LiteralPath $OutputPath
  Write-Output "downloaded=$($item.Name) bytes=$($item.Length)"
}

$Repo = 'Someet24/empathetic-qwen3-8b-Jan'
$OutputDir = Join-Path $env:WINVER_DATA 'copaine\models\empathetic-qwen3-8b-Jan'
$Files = @(
  'README.md',
  'added_tokens.json',
  'chat_template.jinja',
  'config.json',
  'merges.txt',
  'model.safetensors.index.json',
  'special_tokens_map.json',
  'tokenizer.json',
  'tokenizer_config.json',
  'training_config.json',
  'training_history.json',
  'vocab.json',
  'model-00001-of-00004.safetensors',
  'model-00002-of-00004.safetensors',
  'model-00003-of-00004.safetensors',
  'model-00004-of-00004.safetensors'
)

Write-Step 'Model download context'
Write-Output "repo=$Repo"
Write-Output "output_dir=$OutputDir"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

foreach ($File in $Files) {
  $Out = Join-Path $OutputDir $File
  if (Test-Path -LiteralPath $Out -PathType Leaf) {
    $existing = Get-Item -LiteralPath $Out
    if ($existing.Length -gt 0) {
      Write-Output "skip=$File bytes=$($existing.Length)"
      continue
    }
  }

  Write-Step "Download $File"
  $UrlFile = [System.Uri]::EscapeDataString($File).Replace('%2F', '/')
  $Url = "https://huggingface.co/$Repo/resolve/main/${UrlFile}?download=true"
  Invoke-CurlDownload -Url $Url -OutputPath $Out
}

Write-Step 'Model download complete'
Get-ChildItem -LiteralPath $OutputDir -File | Sort-Object Name | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
