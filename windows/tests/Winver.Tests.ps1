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
}

