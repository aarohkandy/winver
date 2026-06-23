BeforeAll {
  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
  . (Join-Path $RepoRoot 'windows\admin\policy.ps1')
}

Describe 'winver admin policy' {
  It 'allows only known actions' {
    Test-WinverAdminAction -Action 'status' | Should -BeTrue
    Test-WinverAdminAction -Action 'server-profile' | Should -BeTrue
    Test-WinverAdminAction -Action 'lockdown' | Should -BeTrue
    Test-WinverAdminAction -Action 'unlock' | Should -BeTrue
    Test-WinverAdminAction -Action 'format-c' | Should -BeFalse
  }

  It 'marks dangerous actions separately' {
    Test-WinverDangerousAction -Action 'server-profile' | Should -BeTrue
    Test-WinverDangerousAction -Action 'lockdown' | Should -BeTrue
    Test-WinverDangerousAction -Action 'unlock' | Should -BeTrue
    Test-WinverDangerousAction -Action 'status' | Should -BeFalse
  }

  It 'generates stable signature payloads' {
    ConvertTo-WinverSignaturePayload -Action 'server-profile' -Mode 'Apply' -RequestId 'abc' -Command '' |
      Should -Be 'server-profile|Apply|abc|'
  }

  It 'verifies HMAC signatures' {
    $payload = ConvertTo-WinverSignaturePayload -Action 'server-profile' -Mode 'Apply' -RequestId 'abc' -Command ''
    $signature = New-WinverHmacSignature -Key 'secret' -Payload $payload
    $signature | Should -Be '2962533db21d0b0ae45edc73290c55f7b291ef57054a3f7b3700814260d77ec2'
    Test-WinverHmacSignature -Key 'secret' -Payload $payload -Signature $signature | Should -BeTrue
    Test-WinverHmacSignature -Key 'wrong' -Payload $payload -Signature $signature | Should -BeFalse
  }
}
