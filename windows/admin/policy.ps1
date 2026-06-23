$script:WinverAdminActions = @(
  'status',
  'power',
  'services',
  'updates',
  'defender',
  'firewall',
  'bitlocker',
  'tpm',
  'battery',
  'thermal',
  'server-profile',
  'lockdown',
  'unlock',
  'rollback',
  'export-recovery',
  'break-glass',
  'reboot',
  'shutdown',
  'admin-shell'
)

$script:WinverDangerousActions = @(
  'server-profile',
  'lockdown',
  'unlock',
  'rollback',
  'export-recovery',
  'break-glass',
  'reboot',
  'shutdown',
  'admin-shell'
)

function Get-WinverAdminKeyPath {
  Join-Path $env:ProgramData 'winver\admin-signing.key'
}

function Get-WinverAdminActions {
  $script:WinverAdminActions
}

function Get-WinverDangerousActions {
  $script:WinverDangerousActions
}

function Test-WinverAdminAction {
  param([Parameter(Mandatory = $true)][string]$Action)
  $script:WinverAdminActions -contains $Action.ToLowerInvariant()
}

function Test-WinverDangerousAction {
  param([Parameter(Mandatory = $true)][string]$Action)
  $script:WinverDangerousActions -contains $Action.ToLowerInvariant()
}

function ConvertTo-WinverSignaturePayload {
  param(
    [Parameter(Mandatory = $true)][string]$Action,
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$RequestId,
    [string]$Command = ''
  )

  @(
    $Action.ToLowerInvariant(),
    $Mode,
    $RequestId,
    $Command
  ) -join '|'
}

function Get-WinverAdminKey {
  param([string]$Path = (Get-WinverAdminKeyPath))

  if ($env:WINVER_ADMIN_KEY) { return $env:WINVER_ADMIN_KEY.Trim() }
  if (Test-Path $Path) { return (Get-Content -Path $Path -Raw).Trim() }
  return ''
}

function New-WinverHmacSignature {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][string]$Payload
  )

  $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Key.Trim()))
  try {
    [BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Payload))).Replace('-', '').ToLowerInvariant()
  } finally {
    $hmac.Dispose()
  }
}

function Test-WinverHmacSignature {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][string]$Payload,
    [Parameter(Mandatory = $true)][string]$Signature
  )

  $expected = New-WinverHmacSignature -Key $Key -Payload $Payload
  $expected.Equals($Signature.ToLowerInvariant(), [StringComparison]::OrdinalIgnoreCase)
}
