BeforeAll {
  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
  . (Join-Path $RepoRoot 'windows\admin\policy.ps1')
}

Describe 'winver admin policy' {
  It 'allows only known actions' {
    Test-WinverAdminAction -Action 'status' | Should -BeTrue
    Test-WinverAdminAction -Action 'server-profile' | Should -BeTrue
    Test-WinverAdminAction -Action 'lockdown' | Should -BeTrue
    Test-WinverAdminAction -Action 'cooling' | Should -BeTrue
    Test-WinverAdminAction -Action 'unlock' | Should -BeTrue
    Test-WinverAdminAction -Action 'format-c' | Should -BeFalse
  }

  It 'marks dangerous actions separately' {
    Test-WinverDangerousAction -Action 'server-profile' | Should -BeTrue
    Test-WinverDangerousAction -Action 'lockdown' | Should -BeTrue
    Test-WinverDangerousAction -Action 'cooling' | Should -BeTrue
    Test-WinverDangerousAction -Action 'unlock' | Should -BeTrue
    Test-WinverDangerousAction -Action 'status' | Should -BeFalse
  }

  It 'generates stable signature payloads' {
    ConvertTo-WinverSignaturePayload -Action 'server-profile' -Mode 'Apply' -RequestId 'abc' -Command '' -Profile '' |
      Should -Be 'server-profile|Apply|abc||'
    ConvertTo-WinverSignaturePayload -Action 'cooling' -Mode 'Apply' -RequestId 'abc' -Command '' -Profile 'max' |
      Should -Be 'cooling|Apply|abc||max'
  }

  It 'verifies HMAC signatures' {
    $payload = ConvertTo-WinverSignaturePayload -Action 'server-profile' -Mode 'Apply' -RequestId 'abc' -Command '' -Profile ''
    $signature = New-WinverHmacSignature -Key 'secret' -Payload $payload
    $signature | Should -Be '696157b66fc7cebf1562e983ed4e1c6024419917dffe653d9e715f597edee158'
    Test-WinverHmacSignature -Key 'secret' -Payload $payload -Signature $signature | Should -BeTrue
    Test-WinverHmacSignature -Key 'wrong' -Payload $payload -Signature $signature | Should -BeFalse
  }
}
