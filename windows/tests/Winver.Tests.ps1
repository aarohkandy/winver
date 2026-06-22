BeforeAll {
  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
}

Describe 'winver Windows scripts' {
  It 'setup.ps1 parses without executing' {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'windows\setup.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
    $errors | Should -BeNullOrEmpty
  }

  It 'doctor.ps1 parses without executing' {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'windows\doctor.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
    $errors | Should -BeNullOrEmpty
  }

  It 'run-job.ps1 parses without executing' {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'windows\run-job.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
    $errors | Should -BeNullOrEmpty
  }

  It 'control.ps1 parses without executing' {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'windows\control.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
    $errors | Should -BeNullOrEmpty
  }

  It 'admin scripts parse without executing' {
    foreach ($script in @(
      'windows\admin\policy.ps1',
      'windows\admin\init-admin.ps1',
      'windows\admin\broker.ps1',
      'windows\admin\uefi.ps1',
      'windows\admin\break-glass.ps1',
      'windows\winver.ps1'
    )) {
      $tokens = $null
      $errors = $null
      [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $script), [ref]$tokens, [ref]$errors) | Out-Null
      $errors | Should -BeNullOrEmpty
    }
  }
}
