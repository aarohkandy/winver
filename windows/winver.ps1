[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Command = 'help',

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$RepoPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

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

Run setup from an elevated PowerShell window:
  .\windows\setup.ps1 -MacPublicKey "ssh-ed25519 ..."
'@
}

switch ($Command) {
  'help' {
    Show-Help
  }
  'doctor' {
    & (Join-Path $RepoPath 'windows\doctor.ps1') @Rest
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
  default {
    throw "Unknown command '$Command'. Run .\windows\winver.ps1 help"
  }
}
