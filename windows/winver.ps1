[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Command = 'help',

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$RepoPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Rest = @($Rest | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

function Show-Help {
  @'
winver for Windows

Usage:
  .\windows\winver.ps1 doctor
  .\windows\winver.ps1 update
  .\windows\winver.ps1 codex
  .\windows\winver.ps1 start "npm run build"
  .\windows\winver.ps1 logs latest
  .\windows\winver.ps1 control status
  .\windows\winver.ps1 status
  .\windows\winver.ps1 server-mode
  .\windows\winver.ps1 admin status
  .\windows\winver.ps1 admin server-profile --dry-run
  .\windows\winver.ps1 admin lockdown --dry-run
  .\windows\winver.ps1 admin unlock --dry-run
  .\windows\winver.ps1 uefi inventory

Run setup from an elevated PowerShell window:
  .\windows\setup.ps1 -MacPublicKey "ssh-ed25519 ..."
'@
}

function New-LocalAdminSignature {
  param(
    [string]$Action,
    [string]$Mode,
    [string]$RequestId,
    [string]$Command = ''
  )

  . (Join-Path $RepoPath 'windows\admin\policy.ps1')
  $key = Get-WinverAdminKey
  if (-not $key) { return '' }
  $payload = ConvertTo-WinverSignaturePayload -Action $Action -Mode $Mode -RequestId $RequestId -Command $Command
  New-WinverHmacSignature -Key $key -Payload $payload
}

function Invoke-LocalAdmin {
  param([string[]]$Args)

  $action = if ($Args.Count -gt 0) { $Args[0] } else { 'status' }
  $mode = 'DryRun'
  $force = $false
  $skipBitLocker = $false
  $commandText = ''
  for ($i = 1; $i -lt $Args.Count; $i++) {
    switch ($Args[$i]) {
      '--apply' { $mode = 'Apply' }
      '--dry-run' { $mode = 'DryRun' }
      '--force' { $force = $true }
      '--skip-bitlocker-check' { $skipBitLocker = $true }
      '--command' {
        if (($i + 1) -lt $Args.Count) {
          $commandText = ($Args[($i + 1)..($Args.Count - 1)] -join ' ')
        }
        $i = $Args.Count
      }
      default {
        if ($action -eq 'admin-shell') {
          if ($i -lt $Args.Count) {
            $commandText = ($Args[$i..($Args.Count - 1)] -join ' ')
          }
          $i = $Args.Count
        } else {
          throw "Unknown admin option '$($Args[$i])'."
        }
      }
    }
  }

  $requestId = [guid]::NewGuid().ToString()
  $signature = New-LocalAdminSignature -Action $action -Mode $mode -RequestId $requestId -Command $commandText
  $brokerParams = @{
    Action = $action
    Mode = $mode
    RequestId = $requestId
  }
  if ($signature) { $brokerParams.Signature = $signature }
  if ($force) { $brokerParams.Force = $true }
  if ($skipBitLocker) { $brokerParams.SkipBitLockerCheck = $true }
  if ($commandText) { $brokerParams.AdminShellCommand = $commandText }
  & (Join-Path $RepoPath 'windows\admin\broker.ps1') @brokerParams
}

function Invoke-Doctor {
  $doctorParams = @{}
  foreach ($arg in $Rest) {
    switch ($arg) {
      '-Json' { $doctorParams.Json = $true }
      '--json' { $doctorParams.Json = $true }
      default {
        if (-not $doctorParams.ContainsKey('RepoPath')) {
          $doctorParams.RepoPath = $arg
        } else {
          throw "Unknown doctor option '$arg'."
        }
      }
    }
  }

  & (Join-Path $RepoPath 'windows\doctor.ps1') @doctorParams
}

switch ($Command) {
  'help' {
    Show-Help
  }
  'doctor' {
    Invoke-Doctor
  }
  'update' {
    Push-Location $RepoPath
    git pull --ff-only
    Pop-Location
  }
  'pull' {
    Push-Location $RepoPath
    git pull --ff-only
    Pop-Location
  }
  'codex' {
    Push-Location $RepoPath
    codex
    Pop-Location
  }
  'start' {
    $line = $Rest -join ' '
    if (-not $line) { throw 'Pass a command, for example: .\windows\winver.ps1 start "npm run build"' }
    & (Join-Path $RepoPath 'windows\run-job.ps1') -Command $line
  }
  'logs' {
    $target = if ($Rest.Count -gt 0) { $Rest[0] } else { 'latest' }
    & (Join-Path $RepoPath 'windows\logs.ps1') -Target $target
  }
  'control' {
    $action = if ($Rest.Count -gt 0) { $Rest[0] } else { 'status' }
    & (Join-Path $RepoPath 'windows\control.ps1') -Action $action
  }
  'status' {
    & (Join-Path $RepoPath 'windows\control.ps1') -Action status
  }
  'server-mode' {
    & (Join-Path $RepoPath 'windows\control.ps1') -Action server-mode
  }
  'admin' {
    Invoke-LocalAdmin -Args $Rest
  }
  'admin-shell' {
    Invoke-LocalAdmin -Args (@('admin-shell') + $Rest)
  }
  'uefi' {
    $action = if ($Rest.Count -gt 0) { $Rest[0] } else { 'inventory' }
    $uefiParams = @{ Action = $action }
    if (($Rest -contains '--json') -or ($Rest -contains '-Json')) { $uefiParams.Json = $true }
    if (($Rest -contains '--local-confirm') -or ($Rest -contains '-LocalConfirm')) { $uefiParams.LocalConfirm = $true }
    & (Join-Path $RepoPath 'windows\admin\uefi.ps1') @uefiParams
  }
  default {
    throw "Unknown command '$Command'. Run .\windows\winver.ps1 help"
  }
}
